#!/usr/bin/env bash
#
# apps/trilium.sh — install + supervise Trilium Notes (the maintained TriliumNext
# fork) as an OPTIONAL hierarchical-notes / wiki app behind the loopback Caddy
# edge, on wiki.${DOMAIN}.
#
# We ship the OFFICIAL first-party aarch64 SERVER tarball, which bundles its own
# Node runtime + a PREBUILT arm64 better-sqlite3 — so there is NO node-gyp / npm
# compile on the supported path (the from-source build is heavy/fragile and is
# explicitly UNsupported; see docs/NOTES.md). Strongest supply-chain position of
# the v0.7 apps: a CI-built, sha256-pinned upstream asset.
#
# What it does (idempotent — review before running):
#   1. installs xz-utils into the userland, downloads + sha256-verifies (fail-
#      closed) the pinned arm64 server tarball, and extracts it to /opt/trilium,
#   2. runs a one-time GLIBCXX boot-smoke: loads the bundled better-sqlite3 native
#      module with the bundled Node, and FAILS CLOSED with a clear message if the
#      userland's libstdc++ is too old (the single most likely on-device failure),
#   3. keeps document.db (+ WAL/SHM) and the whole data dir on ext4
#      ($HOME/.pocket/trilium, bind-mounted to /opt/trilium/data) — NEVER on exFAT,
#   4. FORCES the loopback bind via TRILIUM_NETWORK_HOST=127.0.0.1 (Trilium DEFAULTS
#      to 0.0.0.0 — a LAN-exposure default) and asserts it fail-closed,
#   5. writes a self-contained Caddy vhost + validates fail-closed (no Caddy restart),
#   6. supervises the bundled node on loopback via the shared lib.
#
# AUTH MODEL (default): Trilium's browser UI keeps its OWN password login (you set
# it on first visit) and the hostname is gated at the Cloudflare edge. Because the
# UI is cookie/session based it CAN also sit behind the optional Matrix-SSO
# forward_auth gateway (a COMMENTED block in the vhost) — in which case you may set
# TRILIUM_NOAUTH=true so the gate is the sole auth. We DEFAULT TRILIUM_NOAUTH=false
# (native login ON), the fail-safe: noAuthentication is a footgun if the gate or the
# loopback bind ever fails open. NOTE: the ETAPI REST API + the desktop/mobile SYNC
# client are native-token clients that CANNOT follow a 302 — for those keep native
# auth ON and add a CF Access SERVICE-TOKEN exemption (operator-side). See docs/NOTES.md.
#
# Generalized from the app patterns in this repo; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_TRILIUM=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT version + sha256 (env-overridable, with config/versions.env as the
# central manifest). The asset is the first-party arm64 SERVER build (bundled Node +
# prebuilt better-sqlite3). The hash below is the sha256 of the official release
# asset (cross-checked against GitHub's published asset digest). To upgrade: bump
# TRILIUM_VERSION + TRILIUM_SHA256 together (get the new digest from the release),
# then re-run. document.db is auto-migrated on first start — BACK IT UP first.
TRILIUM_VERSION="${TRILIUM_VERSION:-0.103.0}"
TRILIUM_SHA256="${TRILIUM_SHA256:-4639c70af54847f13167d942f2e906af633c5f51e78f965e54c9901d4bd94ca6}"
TRILIUM_TARBALL="TriliumNotes-Server-v${TRILIUM_VERSION}-linux-arm64.tar.xz"
TRILIUM_URL="${TRILIUM_URL:-https://github.com/TriliumNext/Trilium/releases/download/v${TRILIUM_VERSION}/${TRILIUM_TARBALL}}"
# The extracted top-level dir drops the leading 'v'.
TRILIUM_TOPDIR="TriliumNotes-Server-${TRILIUM_VERSION}-linux-arm64"

# ── Service coordinates ──────────────────────────────────────────────────────
TR_PORT="${TRILIUM_PORT:-9121}"                  # loopback bind; only Caddy reaches it
TR_HOST="wiki.${DOMAIN}"                          # public hostname
TR_NOAUTH="${TRILIUM_NOAUTH:-false}"               # native login ON unless explicitly disabled
INSTALL_DIR=/opt/trilium                           # in userland — app + bundled node
NODE_BIN="${INSTALL_DIR}/node/bin/node"
MAIN_CJS="${INSTALL_DIR}/main.cjs"
VERSION_STAMP="${INSTALL_DIR}/.pocket-installed-version"

# document.db + data dir on ext4 (NOT exFAT), on the HOST under $HOME/.pocket so it
# survives a rootfs rebuild and lives on a real filesystem. Bind-mounted to
# /opt/trilium/data. ── load-bearing for data integrity (better-sqlite3 + WAL). ──
DATA_BACKING="${HOME}/.pocket/trilium"
DATA_MOUNT="${INSTALL_DIR}/data"

CACHE_DIR="${DATA_DIR}/binaries"
TRILIUM_LOCAL="${CACHE_DIR}/${TRILIUM_TARBALL}"

# ── Data dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ───────────────────
case "${DATA_BACKING}" in
  "${DATA_DIR}"|"${DATA_DIR}/"*)
    die "refusing to put the Trilium document.db under DATA_DIR (${DATA_DIR}) — it is exFAT and would corrupt better-sqlite3 + WAL; it must stay on ext4 at \$HOME/.pocket/trilium" ;;
esac
mkdir -p "${DATA_BACKING}" "${CACHE_DIR}" || die "cannot create ${DATA_BACKING} on ext4"
chmod 700 "${DATA_BACKING}" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. xz-utils in the userland (idempotent) ─────────────────────────────────
run_once trilium-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  command -v xz >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y --no-install-recommends xz-utils ca-certificates; }
' || die "could not install xz-utils inside the userland"

# ── 2. Fetch the pinned tarball (sha256 fail-closed) ─────────────────────────
fetch_verified "${TRILIUM_URL}" "${TRILIUM_LOCAL}" "${TRILIUM_SHA256}"
ok "Trilium ${TRILIUM_VERSION} tarball ready at ${TRILIUM_LOCAL} ($(wc -c < "${TRILIUM_LOCAL}") bytes)"

# ── 3. Extract into the userland (idempotent via version stamp) ──────────────
if in_debian "[ -f '${VERSION_STAMP}' ] && grep -qx '${TRILIUM_VERSION}' '${VERSION_STAMP}' 2>/dev/null"; then
  ok "Trilium ${TRILIUM_VERSION} already extracted at ${INSTALL_DIR}"
else
  say "extracting Trilium ${TRILIUM_VERSION} into ${INSTALL_DIR}"
  proot-distro login debian -- bash -lc "
    set -e
    rm -rf /opt/trilium-stage && mkdir -p /opt/trilium-stage
    tar -xJf - -C /opt/trilium-stage
    SRC=\"/opt/trilium-stage/${TRILIUM_TOPDIR}\"
    [ -d \"\$SRC\" ] || SRC=\$(find /opt/trilium-stage -maxdepth 1 -type d -name 'TriliumNotes-Server-*' | head -1)
    [ -n \"\$SRC\" ] && [ -d \"\$SRC\" ] || { echo 'extract: no TriliumNotes-Server-* dir found'; exit 1; }
    mkdir -p '${INSTALL_DIR}'
    # Replace the app code but PRESERVE an existing data/ (it is a bind mount point
    # anyway; this is belt-and-braces).
    find '${INSTALL_DIR}' -maxdepth 1 -mindepth 1 ! -name data -exec rm -rf {} +
    cp -a \"\$SRC\"/. '${INSTALL_DIR}/'
    rm -rf /opt/trilium-stage
    chmod +x '${NODE_BIN}' '${INSTALL_DIR}/trilium.sh' 2>/dev/null || true
    printf '%s\n' '${TRILIUM_VERSION}' > '${VERSION_STAMP}'
  " < "${TRILIUM_LOCAL}" 2>&1 | grep -v 'proot warning' || die "Trilium extract failed"
  ok "Trilium ${TRILIUM_VERSION} extracted to ${INSTALL_DIR}"
fi

in_debian "[ -x '${NODE_BIN}' ] && [ -f '${MAIN_CJS}' ] && [ -d '${INSTALL_DIR}/node_modules/better-sqlite3' ]" \
  || die "Trilium tree incomplete at ${INSTALL_DIR} (need node/bin/node, main.cjs, node_modules/better-sqlite3)"

# ── 4. GLIBCXX boot-smoke (fail-closed) ──────────────────────────────────────
# The single most likely on-device failure is a too-old libstdc++ (better-sqlite3
# is a dynamically-linked native module). Load it with the bundled Node up front so
# a GLIBCXX gap fails HERE with a clear message rather than as a silent crash loop.
say "GLIBCXX boot-smoke: loading the bundled better-sqlite3 native module"
in_debian "cd '${INSTALL_DIR}' && '${NODE_BIN}' -e 'require(\"better-sqlite3\"); console.log(\"better-sqlite3 OK\")'" 2>&1 | grep -v 'proot warning' \
  || die "Trilium's bundled better-sqlite3 failed to load — likely a libstdc++/GLIBCXX too old in the userland. Update the Debian userland (bookworm ships a new-enough libstdc++) or see docs/NOTES.md."
ok "better-sqlite3 loads under the bundled Node (GLIBCXX OK)"

# ── 5. Data dir bind target ──────────────────────────────────────────────────
in_debian "mkdir -p '${DATA_MOUNT}'" || die "failed to create ${DATA_MOUNT} mountpoint in the userland"

# ── 6. In-userland launcher (forces loopback + ext4 data) ────────────────────
# ┌── SECURITY-LOAD-BEARING: TRILIUM_NETWORK_HOST=127.0.0.1 ───────────────────
# │ Trilium DEFAULTS to 0.0.0.0 (confirmed in main.cjs) — we force loopback so the
# │ only path in is Caddy + the Cloudflare Tunnel. Step 7 greps this launcher to
# │ assert it. TRILIUM_DATA_DIR points at the ext4 bind. TRUSTEDREVERSEPROXY=true
# │ lets Trilium read X-Forwarded-* from the loopback Caddy. NOAUTH defaults false.
# └────────────────────────────────────────────────────────────────────────────
say "writing the Trilium launcher (TRILIUM_NETWORK_HOST=127.0.0.1, data on ext4, noAuth=${TR_NOAUTH})"
proot-distro login debian -- bash -lc "umask 077; cat > '${INSTALL_DIR}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/trilium.sh.
cd '${INSTALL_DIR}' || exit 1
export TRILIUM_NETWORK_HOST=127.0.0.1
export TRILIUM_NETWORK_PORT=${TR_PORT}
export TRILIUM_NETWORK_TRUSTEDREVERSEPROXY=true
export TRILIUM_DATA_DIR='${DATA_MOUNT}'
export TRILIUM_GENERAL_NOAUTHENTICATION=${TR_NOAUTH}
exec '${NODE_BIN}' '${MAIN_CJS}'
LAUNCH
in_debian "chmod +x '${INSTALL_DIR}/run.sh'" || die "failed to make ${INSTALL_DIR}/run.sh executable"

# ── 7. FAIL-CLOSED loopback assert ───────────────────────────────────────────
say "asserting the Trilium bind is loopback (guards against the 0.0.0.0 default)"
in_debian "grep -Eq '^export TRILIUM_NETWORK_HOST=127\.0\.0\.1\$' '${INSTALL_DIR}/run.sh'" \
  || die "Trilium launcher does NOT force TRILIUM_NETWORK_HOST=127.0.0.1 — refusing to start a LAN-exposed instance"
ok "Trilium bind confirmed loopback (127.0.0.1:${TR_PORT})"

# ── 8. Caddy vhost (self-contained; imported by the core Caddyfile) ──────────
say "writing the Trilium vhost → /etc/caddy/apps/trilium.caddy"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/trilium.caddy' <<EOF
# wiki.${DOMAIN} — Trilium Notes (hierarchical notes / wiki).
# Written by scripts/apps/trilium.sh. Loopback-only; the Cloudflare Tunnel forwards
# public traffic here and (by default) Cloudflare Access gates the hostname at the
# edge. Trilium keeps its OWN browser login by default. Trilium uses WebSockets for
# live sync — Caddy's reverse_proxy upgrades them automatically.
http://wiki.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (browser UI only). Disabled by default. If
	# enabled, set TRILIUM_NOAUTH=true in .env so the gate is the sole auth, and the
	# three parts MUST precede the reverse_proxy: the /authgw/* handler keeps the
	# login form reachable, the request_header strips any client-forged Remote-User
	# before the gate, and forward_auth gates the rest. (ETAPI + the sync client are
	# native-token clients that need a CF Access service-token exemption instead.)
	# handle /authgw/* {
	# 	reverse_proxy 127.0.0.1:9095 {
	# 		header_up X-Real-IP {client_ip}
	# 	}
	# }
	# request_header -Remote-User
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	reverse_proxy 127.0.0.1:${TR_PORT}
}
EOF
then
  die "failed to write /etc/caddy/apps/trilium.caddy into the userland"
fi

say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/trilium.caddy"
ok "Trilium vhost written + Caddyfile validates"

# ── 9. Supervise the bundled node on loopback ────────────────────────────────
say "supervising Trilium (bundled Node, bind 127.0.0.1:${TR_PORT}; data on ${DATA_BACKING})"
supervise trilium -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- bash "${INSTALL_DIR}/run.sh"

# ── 10. Best-effort health check ──────────────────────────────────────────────
say "waiting for Trilium to answer on 127.0.0.1:${TR_PORT} (first boot builds document.db)"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null -m 3 "http://127.0.0.1:${TR_PORT}/" 2>/dev/null \
     || curl -s -o /dev/null -m 3 "http://127.0.0.1:${TR_PORT}/" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Trilium answering on 127.0.0.1:${TR_PORT}"
else
  warn "Trilium not yet answering on :${TR_PORT} — first boot can be slow on a phone; check ${POCKET_LOG_DIR}/trilium.log (the supervisor keeps retrying)"
fi

# ── 11. Closing notes ─────────────────────────────────────────────────────────
cat >&2 <<EOF

$(ok "Trilium installed + supervised on 127.0.0.1:${TR_PORT} (data on ${DATA_BACKING})" 2>&1)

  FIRST VISIT: with the default native login (TRILIUM_NOAUTH=false), open
  https://${TR_HOST} and complete the one-time setup (set your password). If you
  front it with the optional Matrix-SSO gateway instead, set TRILIUM_NOAUTH=true
  in .env (only when the gate + loopback are confirmed).

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: ${TR_HOST}  ->  http://localhost:${CADDY_PORT}  (plain HTTP).
    2. Cloudflare Access: add an Access policy protecting ${TR_HOST} (Trilium's own
       login is the inner gate). The ETAPI REST API + desktop/mobile SYNC client use
       native tokens and need a CF Access SERVICE-TOKEN exemption — see docs/NOTES.md.

  HEAVY ON-DEMAND: the built-in OCR + spreadsheet note types are CPU/RAM heavy on a
  phone (transient 300-600MB+) — use them sparingly; the supervisor + WAL recover a
  Low-Memory-Killer hit cleanly. Bulk note/attachment imports can exceed the
  Cloudflare ~100MB body cap — do them on loopback/LAN. Back up document.db before
  every upgrade (auto-migration on first start is one-way). See docs/NOTES.md.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
EOF

ok "apps/trilium.sh done (wiki.${DOMAIN} once the Cloudflare hostname + Access policy are added)"

# Generalized from a working deployment; review before running.
