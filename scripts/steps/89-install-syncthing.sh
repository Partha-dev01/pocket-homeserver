#!/usr/bin/env bash
#
# steps/89-install-syncthing.sh — install + supervise SYNCTHING (P2P file sync)
# as an OPTIONAL numbered subsystem (off by default).
#
# Syncthing is the LARGE-DATA path. Unlike every web app in this stack it does NOT
# go through the Cloudflare tunnel: devices find each other and sync directly,
# peer-to-peer, over a mutually-TLS connection where each side pins the other's
# device certificate. That means:
#   - the ~100MB Cloudflare-tunnel body cap is IRRELEVANT here — Syncthing can move
#     arbitrarily large folders because it sidesteps the tunnel entirely;
#   - the local GUI/REST API stays LOOPBACK-ONLY (127.0.0.1:8384). You reach it
#     over an SSH port-forward (ssh -L 8384:127.0.0.1:8384), NOT a Caddy vhost —
#     this step writes NOTHING to /etc/caddy/apps and never touches Caddy;
#   - the sync listener (0.0.0.0:22000 TCP/QUIC) + local-discovery (UDP 21027) ARE
#     bound to all interfaces. That is CORRECT-BY-DESIGN P2P, not a SECURITY.md
#     violation: a peer can only connect if its device-ID (cert) has been mutually
#     approved, so an open port without the right cert gets nothing. A reviewer
#     should NOT "fix" this by binding it to loopback — that would break sync.
#
# Storage tier: the Syncthing HOME (config.xml + device cert + the SQLite index
# DB) is pinned to REAL ext4 ($HOME/.pocket/syncthing). Syncthing 2.x keeps its
# index in SQLite (WAL, heavy fsync, POSIX advisory locks) — that MUST NOT live on
# the exFAT SD card, which has no POSIX locks and refuses rename-over-existing, so
# the DB would corrupt. We assert this fail-closed below.
#
# Trust boundary (relay/discovery metadata): with the stock public infra, the
# global discovery servers (discovery.syncthing.net) and any community relay learn
# your device-ID, your public IP, and the connection graph (who talks to whom).
# File CONTENTS are always end-to-end encrypted and are NOT visible to a relay.
# Running your own stdiscosrv + strelaysrv is a future privacy upgrade.
#
# Core step that SELF-GATES on ENABLE_SYNCTHING (install.sh runs it
# unconditionally; it no-ops when disabled). ENABLE_SYNCTHING defaults to false.
#
# Idempotent — review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when enabled (default off) ───────────────────────────
if [ "${ENABLE_SYNCTHING:-false}" != "true" ]; then
  ok "syncthing disabled (ENABLE_SYNCTHING != true) — skipping"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT syncthing version + sha256 rather than tracking "latest": a fixed
# hash lets us fail closed on a corrupt/tampered tarball. To upgrade: bump both
# together. Get the new hash from the release's sha256sum.txt.asc, or by hashing
# the downloaded tarball once you trust it:
#   sha256sum syncthing-linux-arm64-vX.Y.Z.tar.gz
# Both can also be overridden from the environment without editing this file.
SYNCTHING_VER="${SYNCTHING_VER:-2.1.1}"
SYNCTHING_SHA256="${SYNCTHING_SHA256:-2c831e27c73a5c9217bdbbfcdb695d41b027f9d8bf8303f55590881e7b907f7f}"
SYNCTHING_TGZ="syncthing-linux-arm64-v${SYNCTHING_VER}.tar.gz"
SYNCTHING_URL="https://github.com/syncthing/syncthing/releases/download/v${SYNCTHING_VER}/${SYNCTHING_TGZ}"

CACHE_DIR="${DATA_DIR}/binaries"
SYNCTHING_LOCAL="${CACHE_DIR}/${SYNCTHING_TGZ}"
mkdir -p "${CACHE_DIR}"

# ── 1. Download the tarball to the cache (sha256 fail-closed, cached on re-run) ─
fetch_verified "${SYNCTHING_URL}" "${SYNCTHING_LOCAL}" "${SYNCTHING_SHA256}"

# ── 2. Install just the 'syncthing' binary into the userland /usr/local/bin ────
# The tarball extracts to a directory syncthing-linux-arm64-v${VER}/ that contains
# the 'syncthing' binary plus docs/helpers. NOTE: the archive ALSO ships helper
# scripts named .../etc/firewall-ufw/syncthing and .../etc/freebsd-rc/syncthing —
# they ALSO end in "/syncthing", so a naive `grep /syncthing$ | head -1` can grab a
# config script instead of the binary. Pin the EXACT top-level path (the tarball
# dir is deterministic from the pinned version), then stream just that one file in.
say "locating the syncthing binary inside the tarball"
INNER="syncthing-linux-arm64-v${SYNCTHING_VER}/syncthing"
tar -tzf "${SYNCTHING_LOCAL}" | grep -qxF "${INNER}" \
  || die "could not find the top-level 'syncthing' binary (${INNER}) inside ${SYNCTHING_TGZ}"
ok "binary in tarball: ${INNER}"

say "installing syncthing into the userland (/usr/local/bin)"
in_debian 'mkdir -p /usr/local/bin'
# Extract the single binary to stdout (-O) and stream it into the userland.
tar -xzf "${SYNCTHING_LOCAL}" -O "${INNER}" \
  | proot-distro login debian -- bash -lc 'cat > /usr/local/bin/syncthing && chmod +x /usr/local/bin/syncthing' \
  || die "failed to copy syncthing into the userland"

# ── 3. Verify the binary runs inside the userland (fail-closed) ───────────────
say "verifying syncthing inside the userland"
ver="$(in_debian '/usr/local/bin/syncthing --version 2>&1 | head -1' || true)"
[ -n "${ver}" ] && ok "syncthing: ${ver}" || die "syncthing did not run inside the userland"

# ── 4. HOME pinned to ext4 (LOAD-BEARING) ────────────────────────────────────
# Syncthing 2.x stores config.xml + the device certificate + the SQLite INDEX DB
# all under --home. SQLite needs POSIX locks + rename-over-existing + durable
# fsync — none of which the exFAT SD card (DATA_DIR) provides. If the home ever
# resolves onto exFAT the index WILL corrupt, so we refuse fail-closed.
SYNC_HOME="${POCKET_SYNCTHING_HOME:-$HOME/.pocket/syncthing}"

# SECURITY/INTEGRITY-LOAD-BEARING: assert SYNC_HOME is NOT under the exFAT SD.
# Compare resolved absolute paths so a symlink or "../" can't smuggle it onto the
# SD card. We resolve the *parent* of SYNC_HOME because SYNC_HOME may not exist
# yet on a first run.
mkdir -p "$(dirname "${SYNC_HOME}")"
_resolved_home="$(cd "$(dirname "${SYNC_HOME}")" && pwd -P)/$(basename "${SYNC_HOME}")"
_resolved_data="$(cd "${DATA_DIR}" && pwd -P)"
case "${_resolved_home}/" in
  "${_resolved_data}/"*)
    die "Syncthing HOME (${_resolved_home}) resolves under DATA_DIR (${_resolved_data}, the exFAT SD). The SQLite index DB would corrupt there. Set POCKET_SYNCTHING_HOME to an ext4 path (default \$HOME/.pocket/syncthing) and re-run." ;;
esac

mkdir -p "${SYNC_HOME}" "${POCKET_STATE_DIR}" "${POCKET_LOG_DIR}"
chmod 700 "${SYNC_HOME}" 2>/dev/null || true
ok "syncthing HOME on ext4: ${SYNC_HOME} (config + device cert + SQLite index)"

# ── 5. GUI credentials (SECURITY-LOAD-BEARING) ───────────────────────────────
# The loopback GUI exposes a REST API that can restart the daemon and reveal every
# synced folder path. "Loopback" is NOT "no auth": any other process running as
# this user (or anyone you give an SSH port-forward) could hit it. So we generate
# a random GUI password and bake it into config.xml. Syncthing stores it as a
# bcrypt hash, so the plaintext is never persisted inside the config.
#
# The plaintext IS persisted once, to a 0600 secrets file under
# ${DATA_DIR}/secrets/syncthing.env (umask 077), so a re-run reuses the same
# credentials instead of locking you out, and so you can read them back to log in.
# The password is fed to `syncthing generate` over STDIN (its --gui-password flag,
# set to a single dash, means "read from stdin"), NEVER on the process argv — argv
# is world-readable via /proc on a multi-process host.
SECRETS_DIR="${DATA_DIR}/secrets"
SYNC_SECRETS="${SECRETS_DIR}/syncthing.env"
( umask 077; mkdir -p "${SECRETS_DIR}" )

if [ -f "${SYNC_SECRETS}" ]; then
  # shellcheck disable=SC1090
  . "${SYNC_SECRETS}"
  ok "reusing existing GUI credentials from ${SYNC_SECRETS}"
fi
SYNCTHING_GUI_USER="${SYNCTHING_GUI_USER:-admin}"
if [ -z "${SYNCTHING_GUI_PASSWORD:-}" ]; then
  require_cmd openssl
  # 24 random bytes -> URL-safe-ish base64; strip chars that complicate shells.
  SYNCTHING_GUI_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n')"
  ( umask 077; cat > "${SYNC_SECRETS}" <<SECRETS
# pocket-homeserver — Syncthing loopback GUI credentials (generated; 0600).
# Reused on re-run. Reach the GUI via: ssh -L 8384:127.0.0.1:8384 <phone>
SYNCTHING_GUI_USER=${SYNCTHING_GUI_USER}
SYNCTHING_GUI_PASSWORD=${SYNCTHING_GUI_PASSWORD}
SECRETS
  )
  chmod 600 "${SYNC_SECRETS}" 2>/dev/null || true
  ok "generated GUI credentials -> ${SYNC_SECRETS} (user: ${SYNCTHING_GUI_USER}, 0600)"
fi

# ── 6. Generate config + device cert + GUI creds (idempotent, off-argv) ───────
# `syncthing generate --home=<dir>` creates config.xml + the device certificate if
# they are absent and is safe to re-run (it does not overwrite an existing valid
# config/cert). --gui-user and --gui-password set the GUI auth; the password value
# is a single dash, which makes generate read it from STDIN so it never appears on
# argv. We run this INSIDE the proot so the cert/config are written by the same
# userland that will run `serve`.
say "generating syncthing config + device cert + GUI creds (off-argv via stdin)"
printf '%s' "${SYNCTHING_GUI_PASSWORD}" | proot-distro login debian -- bash -lc \
  "/usr/local/bin/syncthing generate --home='${SYNC_HOME}' --gui-user='${SYNCTHING_GUI_USER}' --gui-password='-' --no-port-probing" \
  || die "syncthing generate failed (config/cert not created)"
ok "syncthing config + device cert ready under ${SYNC_HOME}"

# ── 7. Supervise ─────────────────────────────────────────────────────────────
# Run INSIDE the proot userland (the cert/config/DB live there on ext4).
#   --no-browser : never try to open a browser (headless phone).
#   --no-restart : hand restart control to common.sh's supervise() respawn loop;
#                  Syncthing's own self-restart would fight the supervisor.
# supervise records this exact command in <name>.cmd so start-stack.sh and
# ops/restart.sh re-supervise it verbatim on every bring-up.
supervise syncthing -- proot-distro login debian -- \
  /usr/local/bin/syncthing serve --no-browser --no-restart --home="${SYNC_HOME}"

# ── 8. Health (best-effort, not fatal) ───────────────────────────────────────
# Confirm the loopback GUI came up. The REST API needs an API key, but the bare
# GUI endpoint answers HTTP (often 401/200) once the daemon is listening — any
# response means the process bound the port. We only warn if it never appears.
say "confirming the syncthing GUI came up on 127.0.0.1:8384"
up=0
for _ in $(seq 1 15); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:8384/" 2>/dev/null \
     || curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:8384/" 2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] && ok "syncthing GUI reachable on 127.0.0.1:8384" \
  || warn "syncthing GUI not reachable yet — check ${POCKET_LOG_DIR}/syncthing.log"

# ── Closing notes (operator guidance — NOT enforced here) ────────────────────
echo
ok "Syncthing installed + supervised (HOME: ${SYNC_HOME})"
say "GUI is loopback-only. Reach it from your laptop with an SSH port-forward:"
say "    ssh -L 8384:127.0.0.1:8384 <phone>   then open http://127.0.0.1:8384/"
say "GUI login lives in ${SYNC_SECRETS} (user: ${SYNCTHING_GUI_USER}, 0600)."
echo
say "Synced-folder guidance (Syncthing won't stop you, but heed this):"
say " - Default your synced folders to ext4 paths. The exFAT SD (${DATA_DIR}) is an"
say "   EXPLICITLY-WARNED, UNSUPPORTED sync target: Syncthing writes to a temp file"
say "   then renames it over the destination, which exFAT/FUSE refuses — you get"
say "   '.tmp never renamed', stuck out-of-sync items, and possible corruption."
say " - If you sync anywhere without unix permissions, enable 'Ignore Permissions'"
say "   on that folder, or it will flag spurious permission changes forever."
say " - Under proot there is no inotify (unrootable on stock Android), so Syncthing"
say "   falls back to periodic rescans. Pick a conservative rescanIntervalS to trade"
say "   sync latency for battery (default 3600s is fine for most folders)."
say " - Android Doze can pause sync; the Termux:Boot wake-lock keeps it running."
echo
say "Trust boundary: the public discovery + community relays learn your device-ID,"
say "public IP, and connection graph; file CONTENTS stay end-to-end encrypted."
say "Self-hosting stdiscosrv + strelaysrv is a future privacy upgrade."
say "0.0.0.0:22000 (+ UDP 21027 discovery) is correct-by-design P2P — do not"
say "rebind it to loopback. See docs/FILES.md for the files & sync overview."

# Idempotent — review before running.
