#!/usr/bin/env bash
#
# apps/memos.sh — install Memos (lightweight self-hosted notes / quick-capture)
# into the Debian userland and wire it into the loopback edge.
#
# What it does:
#   - downloads the pinned Memos linux-arm64 release tarball (exact version +
#     sha256 as a fail-closed supply-chain check) into ${DATA_DIR}/binaries,
#   - extracts the single static Go binary into the userland at /opt/memos/memos
#     and verifies it runs,
#   - keeps Memos' data (SQLite db + uploads) on the large volume at
#     ${DATA_DIR}/memos and bind-mounts it into the userland at /opt/memos-data
#     so it survives a rootfs rebuild,
#   - writes a self-contained Caddy site block for notes.${DOMAIN} to
#     /etc/caddy/apps/memos.caddy in the userland (the core Caddyfile imports
#     /etc/caddy/apps/*.caddy) and validates it fail-closed,
#   - supervises the Memos binary on loopback 127.0.0.1:9110.
#
# Auth model: by DEFAULT, Memos is gated at the Cloudflare edge (Cloudflare
# Access — configured by you in the Cloudflare dashboard, NOT in this script)
# and Memos keeps its OWN native login. Memos ships with OPEN sign-up, so a
# private server MUST disable public registration in Memos' settings (see the
# closing notes). The optional Matrix-SSO gateway is an advanced add-on: a
# commented `forward_auth` block in the vhost shows where it would hook in.
# See docs/APP_AUTH.md.
#
# Memos is configured entirely by flags + env — there is no auth section in any
# config file. SSO, if used, is stored in Memos' own SQLite DB via its admin UI.
#
# Idempotent + re-runnable. Generalized from a working deployment; review before
# running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Memos version + sha256 rather than tracking "latest", so the
# download fails closed on any corruption/tampering. Both are env-overridable
# without editing this file.
#
# To upgrade: bump MEMOS_VER and MEMOS_SHA256 *together* (get the new hash from
# the release checksums, or by hashing a tarball you already trust:
#   sha256sum memos_<ver>_linux_arm64.tar.gz
# ), then re-run this script. Memos' data (incl. any SSO config in its DB)
# persists across upgrades because it lives on ${DATA_DIR}/memos.
MEMOS_VER="${MEMOS_VER:-0.29.0}"
MEMOS_SHA256="${MEMOS_SHA256:-ed8379f95250ecff330332d403182120e7498032006e1e73d91cf0f1831087be}"
MEMOS_ARCH="arm64"
MEMOS_TARBALL="memos_${MEMOS_VER}_linux_${MEMOS_ARCH}.tar.gz"
MEMOS_URL="${MEMOS_URL:-https://github.com/usememos/memos/releases/download/v${MEMOS_VER}/${MEMOS_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
MEMOS_PORT=9110                          # loopback bind; only Caddy reaches it
MEMOS_HOST="notes.${DOMAIN}"             # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/memos                   # in userland — the binary
BIN="${INSTALL_DIR}/memos"               # in userland — /opt/memos/memos
DATA_MOUNT=/opt/memos-data               # in userland — bind-mount target (SQLite + uploads)
DATA_BACKING="${DATA_DIR}/memos"         # on the large volume — survives rootfs rebuild

CACHE_DIR="${DATA_DIR}/binaries"
MEMOS_LOCAL="${CACHE_DIR}/${MEMOS_TARBALL}"
mkdir -p "${CACHE_DIR}"

# ── 1. Download the release tarball, sha256-verified fail-closed ─────────────
# fetch_verified (from common.sh) reuses a cached copy that already matches the
# pin, and deletes + aborts on any mismatch.
fetch_verified "${MEMOS_URL}" "${MEMOS_LOCAL}" "${MEMOS_SHA256}"
ok "Memos v${MEMOS_VER} tarball ready at ${MEMOS_LOCAL} ($(wc -c < "${MEMOS_LOCAL}") bytes)"

# ── 2. Extract the binary into the userland + verify it runs ─────────────────
# proot-distro manages the rootfs path, so go through `proot-distro login` and
# stream the tarball in over stdin (no hardcoded rootfs location). The release
# tarball contains a single `memos` binary at its top level.
say "extracting Memos into the userland (${BIN})"
in_debian "mkdir -p ${INSTALL_DIR}"
proot-distro login debian -- bash -lc "tar -xzf - -C ${INSTALL_DIR} && chmod +x ${BIN}" \
  < "${MEMOS_LOCAL}" || die "failed to extract the Memos binary into the userland"
in_debian "[ -x ${BIN} ]" || die "Memos binary missing after extract at ${BIN}"
ver="$(in_debian "${BIN} --version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "Memos: ${ver}" || die "Memos binary did not run inside the userland"

# ── 3. Data dir on the large volume (SQLite + uploads) ───────────────────────
# Memos keeps its SQLite db (memos_prod.db) + uploaded blobs in its data dir.
# We put it on ${DATA_DIR} (the big volume) and bind-mount it into the userland
# at run time (see step 5), mirroring how the Matrix media dir is bound. We
# create both the backing dir on the volume AND the in-userland mountpoint.
say "creating Memos data dir on the large volume (${DATA_BACKING})"
mkdir -p "${DATA_BACKING}" || die "cannot create ${DATA_BACKING} on the data volume"
chmod 700 "${DATA_BACKING}" 2>/dev/null || true
in_debian "mkdir -p ${DATA_MOUNT}" || die "failed to create the ${DATA_MOUNT} mountpoint in the userland"
ok "Memos data backing dir ready: ${DATA_BACKING} (bind-mounted at ${DATA_MOUNT} at start time)"

# ── 4. Caddy vhost → /etc/caddy/apps/memos.caddy (validate fail-closed) ──────
# A self-contained site block so enabling Memos never requires hand-editing the
# core Caddyfile (it imports /etc/caddy/apps/*.caddy). The listener style MUST
# match the other vhosts: explicit `http://<host>:${CADDY_PORT}` + `bind
# ${CADDY_BIND}` (plain HTTP on the shared high loopback port; the Cloudflare
# Tunnel terminates public TLS). The explicit http:// scheme stops Caddy
# inferring HTTPS-on-:443, which an unprivileged proot Caddy cannot bind.
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, and ${MEMOS_PORT}.
say "writing the Memos vhost to /etc/caddy/apps/memos.caddy in the userland"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/memos.caddy' <<EOF
# notes.${DOMAIN} — Memos (notes / quick-capture).
# Written by scripts/apps/memos.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here and (by default) Cloudflare Access gates the
# hostname at the edge — see docs/APP_AUTH.md.
http://notes.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md).
	# By default this stays COMMENTED OUT: the hostname is gated by Cloudflare
	# Access at the edge and Memos keeps its own native login. To front Memos
	# with the Matrix-SSO gateway instead, run that add-on and uncomment:
	#
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	# Everything → the Memos backend on loopback.
	reverse_proxy 127.0.0.1:${MEMOS_PORT}
}
EOF
then
  die "failed to write /etc/caddy/apps/memos.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so
# we never leave a broken edge config in place.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/memos.caddy"
ok "Memos vhost written + Caddyfile validates"

# NOTE: we do NOT restart Caddy here. During a full install the stack is started
# afterward (scripts/start-stack.sh). If the stack is ALREADY running, the new
# vhost is not live until Caddy reloads — see the closing notes.

# ── 5. Supervise Memos on loopback ───────────────────────────────────────────
# Memos is configured by flags + env (there is NO --mode flag in 0.29.0 — it was
# removed; passing it crash-loops. Mode is env-only now, hence MEMOS_MODE=prod).
# --addr 127.0.0.1 keeps it unreachable except through Caddy; --data points at
# the bind-mounted dir so the SQLite db + uploads land on the large volume. The
# lib's supervisor respawns it on crash with an identity-checked pidfile.
say "supervising Memos (Go binary in the userland, bind 127.0.0.1:${MEMOS_PORT})"
supervise memos -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- env MEMOS_MODE=prod MEMOS_DRIVER=sqlite \
       "${BIN}" --addr 127.0.0.1 --port "${MEMOS_PORT}" --data "${DATA_MOUNT}"

# ── 6. Best-effort health check ──────────────────────────────────────────────
# The Go binary + proot cold start can take a few seconds; poll the loopback
# port. A non-200 here is a WARNING (the supervisor keeps retrying), not fatal.
say "waiting for Memos to answer on 127.0.0.1:${MEMOS_PORT}"
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:${MEMOS_PORT}/" >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Memos healthy on 127.0.0.1:${MEMOS_PORT}"
else
  warn "Memos not yet answering on :${MEMOS_PORT} — check ${POCKET_LOG_DIR}/memos.log (the supervisor keeps retrying)"
fi

# ── 7. Closing notes (manual Cloudflare + hardening) ─────────────────────────
cat >&2 <<EOF

$(ok "Memos installed + supervised on 127.0.0.1:${MEMOS_PORT}" 2>&1)

  Manual steps to finish (in the Cloudflare dashboard):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${MEMOS_HOST}  ->  http://localhost:${CADDY_PORT}
       (the tunnel's local service is this phone's loopback Caddy edge; plain
        HTTP — the tunnel terminates public TLS).
    2. Cloudflare Access: add an Access application/policy covering
         ${MEMOS_HOST}
       so only people you allow can reach Memos. By default this is the ONLY
       gate in front of Memos.

  Hardening — DISABLE OPEN REGISTRATION (do this once Memos is up):
    Memos ships with PUBLIC sign-up ON. On a private server you MUST turn it
    off, or anyone who reaches the page can self-register. After creating your
    own admin account, in the Memos UI go to:
         Settings -> System (admin)  ->  disable "Allow user signup"
                                     (and "Disallow password auth" if you only
                                      want SSO).
    This is essential even with Cloudflare Access in front.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).

  Optional Matrix-SSO gateway add-on: see the commented forward_auth block in
  /etc/caddy/apps/memos.caddy and docs/APP_AUTH.md.
EOF

ok "apps/memos.sh done (notes.${DOMAIN} once the Cloudflare hostname + Access policy are added)"
