#!/usr/bin/env bash
#
# steps/90-install-tailscale.sh — install + supervise TAILSCALE (userspace mesh
# VPN) as an OPTIONAL numbered subsystem (off by default).
#
# WHAT THIS IS
#   Tailscale is a WireGuard-based mesh VPN. It joins this phone to your private
#   "tailnet" so your other devices (laptop, phone) can reach the box's loopback
#   services directly over the encrypted mesh — NO public Cloudflare hostname, no
#   Caddy vhost. Like Syncthing (steps/89), it sidesteps the Cloudflare tunnel
#   entirely, so the ~100MB tunnel body cap is IRRELEVANT for anything reached over
#   the tailnet.
#
# USERSPACE / NON-ROOT MODE (load-bearing for this stack)
#   A normal Android phone has no root and proot cannot open /dev/net/tun. So we run
#   tailscaled in USERSPACE-NETWORKING mode (`--tun=userspace-networking`): no TUN
#   device, no kernel routing, no root. Outbound connectivity FROM the box over the
#   tailnet is then exposed as a local SOCKS5 + HTTP proxy (default 127.0.0.1:1055).
#   INBOUND reachability — your laptop hitting this box's services over the tailnet —
#   works for anything Tailscale itself proxies (e.g. `tailscale serve`); plain
#   loopback services are reachable from the tailnet via that same userspace stack.
#
# ┌── TRUST BOUNDARY — READ THIS (CF-ACCESS BYPASS) ───────────────────────────────
# │ Everything reached over the tailnet COMPLETELY BYPASSES Cloudflare Access and
# │ the Cloudflare Tunnel. CF Access only gates the *.${DOMAIN} public hostnames;
# │ it has ZERO say over tailnet traffic. The ONLY gate for anything reachable over
# │ the tailnet is your TAILNET ACL (the access-control policy in the Tailscale
# │ admin console). If your ACL is the default "allow all within the tailnet", then
# │ every device on your tailnet can reach this box's loopback services with NO
# │ further auth. Lock the ACL down (and the per-app native logins stay in force on
# │ top). See docs — this is the single most important thing to get right.
# └────────────────────────────────────────────────────────────────────────────────
#
# STORAGE TIER
#   tailscaled keeps persistent node state (the WireGuard private key, the node
#   identity, prefs) under --statedir. That is a tiny but integrity-critical store:
#   we pin it to REAL ext4 ($HOME/.pocket/tailscale) and REFUSE ${DATA_DIR} (the
#   exFAT SD) fail-closed — exFAT has no POSIX locks / atomic rename / durable
#   fsync, and a corrupt key store means a re-auth at best. The control socket lives
#   alongside it on ext4 (the default /var/run/tailscale is not writable for a
#   non-root proot user).
#
# AUTH
#   `tailscale up` needs an operator-provided AUTH KEY (mint one in the Tailscale
#   admin console → Settings → Keys). We read it from a 0600 secrets file and pass
#   it to `tailscale up --auth-key file:<path>` — the `file:` scheme means only the
#   PATH appears on argv, never the key itself (argv is world-readable via /proc on
#   a multi-process host). The module FAILS CLOSED if no auth key is present: it
#   installs + supervises the daemon but refuses the half-configured `up`.
#
# Core step that SELF-GATES on ENABLE_TAILSCALE (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_TAILSCALE defaults to false.
#
# Idempotent — review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_TAILSCALE:-false}" != "true" ]; then
  ok "tailscale disabled (ENABLE_TAILSCALE != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl
require_cmd tar

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Tailscale version + sha256 rather than tracking "latest", so the
# download fails closed on any corruption/tampering. Both are env-overridable (and
# centrally pinned in config/versions.env) without editing this file.
#
# The tarball ships BOTH statically-linked binaries (tailscaled + tailscale). To
# upgrade: bump TS_VER + TS_SHA256 *together* and re-run. Get the new hash by
# hashing a tarball you trust:  sha256sum tailscale_<ver>_arm64.tgz
TS_VER="${TS_VER:-1.98.4}"
TS_SHA256="${TS_SHA256:-3cb068eb1368b6bb218d0ef0aa0a7a679a7156b7c979e2279cc2c2321b5f05c7}"
TS_TARBALL="tailscale_${TS_VER}_arm64.tgz"
TS_URL="${TS_URL:-https://pkgs.tailscale.com/stable/${TS_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
INSTALL_DIR=/opt/tailscale                 # in userland — the two binaries
TAILSCALED_BIN="${INSTALL_DIR}/tailscaled" # in userland
TAILSCALE_BIN="${INSTALL_DIR}/tailscale"   # in userland (CLI)
# SOCKS5 + outbound HTTP proxy: BOTH share one loopback port (Tailscale 1.20+ runs
# them on the same listener). Default 127.0.0.1:1055 — loopback only.
TS_SOCKS5="${TS_SOCKS5:-127.0.0.1:1055}"

CACHE_DIR="${DATA_DIR}/binaries"
TS_LOCAL="${CACHE_DIR}/${TS_TARBALL}"
mkdir -p "${CACHE_DIR}"

# ── SOCKS5/HTTP-proxy listen address MUST be loopback (pre-launch assert) ────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ TS_SOCKS5 is env-overridable; refuse anything that is not a 127.0.0.1 literal
# │ (or [::1]) so an operator override can never expose the SOCKS5/HTTP proxy on
# │ the phone's real Wi-Fi/cell interface. proot shares the host network namespace,
# │ so a 0.0.0.0/wildcard listener here would be a real LAN exposure.
# └────────────────────────────────────────────────────────────────────────────
case "${TS_SOCKS5}" in
  127.0.0.1:*|localhost:*|"[::1]:"*) : ;;
  *) die "TS_SOCKS5 ('${TS_SOCKS5}') is not a loopback address — refusing to bind the SOCKS5/HTTP proxy on a non-loopback interface; set TS_SOCKS5=127.0.0.1:<port>" ;;
esac
ok "tailscaled SOCKS5/HTTP proxy listen confirmed loopback (${TS_SOCKS5})"

# ── 1. Download the tarball to the cache (sha256 fail-closed, cached on re-run) ─
fetch_verified "${TS_URL}" "${TS_LOCAL}" "${TS_SHA256}"
ok "Tailscale v${TS_VER} tarball ready at ${TS_LOCAL} ($(wc -c < "${TS_LOCAL}") bytes)"

# ── 2. Install BOTH binaries into the userland (pin EXACT tarball paths) ──────
# The tarball extracts to a directory tailscale_${TS_VER}_arm64/ that contains
# tailscaled + tailscale plus systemd unit samples (.../systemd/...). Several
# entries end in "/tailscale" or "/tailscaled", so a naive glob can grab a unit
# file. Pin the EXACT top-level paths (deterministic from the pinned version) and
# stream just those two files in — the same discipline as the syncthing step.
INNER_DIR="tailscale_${TS_VER}_arm64"
INNER_DAEMON="${INNER_DIR}/tailscaled"
INNER_CLI="${INNER_DIR}/tailscale"
say "locating tailscaled + tailscale inside the tarball"
tar -tzf "${TS_LOCAL}" | grep -qxF "${INNER_DAEMON}" \
  || die "could not find the top-level 'tailscaled' (${INNER_DAEMON}) inside ${TS_TARBALL}"
tar -tzf "${TS_LOCAL}" | grep -qxF "${INNER_CLI}" \
  || die "could not find the top-level 'tailscale' (${INNER_CLI}) inside ${TS_TARBALL}"
ok "binaries in tarball: ${INNER_DAEMON}, ${INNER_CLI}"

say "installing tailscaled + tailscale into the userland (${INSTALL_DIR})"
in_debian "mkdir -p ${INSTALL_DIR}"
# Extract each single binary to stdout (-O) and stream it into the userland.
tar -xzf "${TS_LOCAL}" -O "${INNER_DAEMON}" \
  | proot-distro login debian -- bash -lc "cat > ${TAILSCALED_BIN} && chmod +x ${TAILSCALED_BIN}" \
  || die "failed to copy tailscaled into the userland"
tar -xzf "${TS_LOCAL}" -O "${INNER_CLI}" \
  | proot-distro login debian -- bash -lc "cat > ${TAILSCALE_BIN} && chmod +x ${TAILSCALE_BIN}" \
  || die "failed to copy tailscale into the userland"

# ── 3. Verify the binaries run inside the userland (fail-closed) ──────────────
say "verifying tailscale inside the userland"
ver="$(in_debian "${TAILSCALE_BIN} version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "tailscale: ${ver}" || die "tailscale did not run inside the userland"
in_debian "[ -x ${TAILSCALED_BIN} ]" || die "tailscaled missing/!executable after extract at ${TAILSCALED_BIN}"

# ── 4. State dir pinned to ext4 — REFUSE DATA_DIR (exFAT) fail-closed ────────
# tailscaled persists the node's WireGuard private key + identity + prefs under
# --statedir. We force it onto ext4 ($HOME/.pocket/tailscale). exFAT (DATA_DIR)
# has no POSIX locks / atomic rename / durable fsync; a corrupt key store there
# means a re-auth at best, silent breakage at worst. The shared helper resolves the
# full real path (incl. a symlinked leaf) and refuses fail-closed.
TS_STATEDIR="${POCKET_TAILSCALE_STATEDIR:-$HOME/.pocket/tailscale}"
assert_ext4 "${TS_STATEDIR}" "Tailscale statedir (node key + identity + prefs)"
mkdir -p "${TS_STATEDIR}" "${POCKET_STATE_DIR}" "${POCKET_LOG_DIR}"
chmod 700 "${TS_STATEDIR}" 2>/dev/null || true
ok "tailscale statedir on ext4: ${TS_STATEDIR} (node key + identity + prefs)"

# The control socket: tailscaled defaults it to /var/run/tailscale/tailscaled.sock,
# which a non-root proot user usually cannot create. Put it next to the state on
# ext4, and point the CLI at the SAME socket for `up`/`status`.
TS_SOCK="${TS_STATEDIR}/tailscaled.sock"

# ── 5. Auth key off-argv — FAIL CLOSED if absent ─────────────────────────────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ `tailscale up` needs an operator-minted auth key. We NEVER place it on argv:
# │ tailscale's `--auth-key file:<path>` scheme reads the key from a file, so only
# │ the PATH is on the command line (verified: cmd/tailscale/cli/up.go — "if it
# │ begins with 'file:', then it's a path to a file containing the authkey").
# │ The key lives in a 0600 file. We accept either:
# │   - ${DATA_DIR}/secrets/tailscale.env  (TS_AUTHKEY=tskey-auth-...), or
# │   - $HOME/.pocket/tailscale/authkey    (the raw key, one line).
# │ The module FAILS CLOSED with guidance if neither is present — we install +
# │ supervise the daemon but refuse to half-configure with a missing key.
# └────────────────────────────────────────────────────────────────────────────
SECRETS_DIR="${DATA_DIR}/secrets"
TS_SECRETS_ENV="${SECRETS_DIR}/tailscale.env"
TS_AUTHKEY_FILE="${TS_STATEDIR}/authkey"   # the file we hand to `--auth-key file:`
( umask 077; mkdir -p "${SECRETS_DIR}" )

# Resolve the key into TS_AUTHKEY_FILE (0600) without ever echoing it.
_have_key=0
if [ -s "${TS_AUTHKEY_FILE}" ]; then
  # Already materialized on a prior run (ext4, next to state). Reuse.
  _have_key=1
elif [ -f "${TS_SECRETS_ENV}" ]; then
  # shellcheck disable=SC1090
  . "${TS_SECRETS_ENV}"
  if [ -n "${TS_AUTHKEY:-}" ]; then
    ( umask 077; printf '%s\n' "${TS_AUTHKEY}" > "${TS_AUTHKEY_FILE}" )
    chmod 600 "${TS_AUTHKEY_FILE}" 2>/dev/null || true
    unset TS_AUTHKEY
    _have_key=1
  fi
fi

# ── 6. Supervise tailscaled on loopback (userspace networking) ───────────────
# Run INSIDE the proot userland with the ext4 statedir bind-mounted in. Flags:
#   --tun=userspace-networking      : NO /dev/net/tun, no root (mandatory here).
#   --statedir=<ext4>               : node key + identity + prefs (NEVER exFAT).
#   --socket=<ext4>/tailscaled.sock : control socket on ext4 (default /var/run is
#                                     not writable for a non-root proot user).
#   --socks5-server=${TS_SOCKS5}    : outbound SOCKS5 proxy (loopback-asserted).
#   --outbound-http-proxy-listen    : outbound HTTP proxy on the SAME loopback port.
# GOMEMLIMIT caps the Go heap so a sync/route storm cannot OOM the phone; the Go
# runtime treats this as a soft limit and GCs harder rather than ballooning.
# supervise records this exact argv to <name>.cmd so start-stack.sh + ops/restart.sh
# re-supervise it verbatim, and the respawn loop + identity-checked pidfile handle
# crash recovery (tailscaled has no self-restart to fight here).
STATE_MOUNT="${INSTALL_DIR}/state"   # in-userland bind target for the ext4 statedir
in_debian "mkdir -p ${STATE_MOUNT}" || die "failed to create the ${STATE_MOUNT} mountpoint in the userland"
TS_SOCK_IN="${STATE_MOUNT}/tailscaled.sock"   # the socket path AS SEEN inside the userland
TS_GOMEMLIMIT="${TS_GOMEMLIMIT:-128MiB}"

say "supervising tailscaled (userspace networking, statedir on ext4 → ${STATE_MOUNT})"
supervise tailscaled -- \
  proot-distro login debian \
  --bind "${TS_STATEDIR}:${STATE_MOUNT}" \
  -- env GOMEMLIMIT="${TS_GOMEMLIMIT}" \
         "${TAILSCALED_BIN}" \
         --tun=userspace-networking \
         --statedir="${STATE_MOUNT}" \
         --socket="${TS_SOCK_IN}" \
         --socks5-server="${TS_SOCKS5}" \
         --outbound-http-proxy-listen="${TS_SOCKS5}"

# ── 7. Wait for the daemon's control socket to come up ───────────────────────
# `tailscale --socket=<sock> status` answers once tailscaled is listening on its
# socket (even before login). We poll INSIDE the userland against the bound socket.
say "waiting for tailscaled control socket"
sock_up=0
for _ in $(seq 1 30); do
  if in_debian "${TAILSCALE_BIN} --socket=${TS_SOCK_IN} status >/dev/null 2>&1 || ${TAILSCALE_BIN} --socket=${TS_SOCK_IN} status 2>&1 | grep -qiE 'logged|stopped|NoState|Needs'"; then
    sock_up=1; break
  fi
  sleep 1
done
[ "${sock_up}" -eq 1 ] && ok "tailscaled control socket is up" \
  || warn "tailscaled socket not responding yet — check ${POCKET_LOG_DIR}/tailscaled.log (the supervisor keeps retrying)"

# ── 8. FAIL-CLOSED if no auth key (do NOT half-configure) ────────────────────
if [ "${_have_key}" -ne 1 ]; then
  echo >&2
  die "no Tailscale auth key found — the daemon is supervised but NOT joined to your tailnet.
  Mint a key in the Tailscale admin console (Settings -> Keys -> Generate auth key),
  then store it OFF the command line in ONE of:
    - ${TS_SECRETS_ENV}      (0600 file, line:  TS_AUTHKEY=tskey-auth-...)
    - ${TS_AUTHKEY_FILE}     (0600 file, the raw key on one line)
  and re-run:  bash ${POCKET_ROOT}/scripts/steps/90-install-tailscale.sh
  (Refusing to bring the node up half-configured.)"
fi
[ -s "${TS_AUTHKEY_FILE}" ] || die "auth key file ${TS_AUTHKEY_FILE} is empty — check your secret and re-run"
chmod 600 "${TS_AUTHKEY_FILE}" 2>/dev/null || true

# ── 9. Bring the node up (idempotent via run_once; key OFF-ARGV via file:) ───
# The auth key is passed as `--auth-key file:<path>` so only the path appears on
# argv. The statedir bind makes ${TS_AUTHKEY_FILE} visible at ${STATE_MOUNT}/authkey
# inside the userland. --hostname names the node in your tailnet. run_once marks it
# done so re-runs do not re-`up` an already-joined node (the marker lives in
# POCKET_STATE_DIR; clear it to force a re-auth).
TS_HOSTNAME="${TS_HOSTNAME:-pocket-${DOMAIN%%.*}}"
[ -n "${TS_HOSTNAME}" ] || TS_HOSTNAME="pocket"
AUTHKEY_IN="${STATE_MOUNT}/authkey"   # the key file AS SEEN inside the userland

say "bringing the tailscale node up as '${TS_HOSTNAME}' (auth key off-argv via file:)"
_ts_up() {
  proot-distro login debian \
    --bind "${TS_STATEDIR}:${STATE_MOUNT}" \
    -- "${TAILSCALE_BIN}" --socket="${TS_SOCK_IN}" up \
       --auth-key="file:${AUTHKEY_IN}" \
       --hostname="${TS_HOSTNAME}" \
       --accept-dns=false
}
run_once tailscale-up -- _ts_up \
  || warn "tailscale up did not complete — verify the auth key is valid + unexpired, then clear the marker and re-run: rm -f \"${POCKET_STATE_DIR}/tailscale-up.done\"; bash ${POCKET_ROOT}/scripts/steps/90-install-tailscale.sh"

# ── 10. Report tailnet status (best-effort, never fatal) ─────────────────────
say "tailnet status:"
in_debian "${TAILSCALE_BIN} --socket=${TS_SOCK_IN} status 2>&1 | head -20" || true

# ── Closing notes (operator guidance — the trust boundary, restated loud) ────
echo >&2
ok "Tailscale installed + supervised (userspace; statedir ${TS_STATEDIR})"
say "Node hostname on your tailnet: ${TS_HOSTNAME}"
say "Outbound SOCKS5 + HTTP proxy (loopback): ${TS_SOCKS5}"
echo >&2
warn "TRUST BOUNDARY — anything reachable over the tailnet COMPLETELY BYPASSES"
warn "Cloudflare Access + the Cloudflare Tunnel. CF Access only gates *.${DOMAIN}."
warn "Your TAILNET ACL (Tailscale admin console) is the ONLY gate for tailnet"
warn "traffic. The default 'allow all within tailnet' means every device on your"
warn "tailnet can reach this box's loopback services with no further auth — lock"
warn "the ACL down. Per-app native logins still apply on top. See the docs."
echo >&2
say "Auth key (0600) materialized at: ${TS_AUTHKEY_FILE}"
say "To re-auth after key rotation: update ${TS_SECRETS_ENV} (or ${TS_AUTHKEY_FILE}),"
say "then: rm -f \"${POCKET_STATE_DIR}/tailscale-up.done\"; bash ${POCKET_ROOT}/scripts/steps/90-install-tailscale.sh"

# Idempotent — review before running.
