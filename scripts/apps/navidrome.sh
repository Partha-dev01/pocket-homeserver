#!/usr/bin/env bash
#
# apps/navidrome.sh — install Navidrome (self-hosted music streaming server,
# Subsonic-compatible) into the Debian userland and wire it into the loopback edge
# on music.${DOMAIN}.
#
# What it does:
#   - downloads the pinned Navidrome linux-arm64 release tarball (exact version +
#     sha256 as a fail-closed supply-chain check) into ${DATA_DIR}/binaries,
#   - extracts the single static Go binary (+ its resources/ dir) into the userland
#     at /opt/navidrome and verifies it runs,
#   - keeps ALL of Navidrome's state — the SQLite db (navidrome.db) + its -wal/-shm,
#     the artwork/transcode CACHE, plugin dirs, scan index — on EXT4
#     ($HOME/.pocket/navidrome, bind-mounted to /opt/navidrome/data). It REFUSES
#     ${DATA_DIR} (exFAT) fail-closed: SQLite WAL needs real fsync + atomic rename +
#     POSIX locks, which exFAT cannot provide → DB corruption (a verified failure
#     class on this stack — see docs/RESILIENCE.md),
#   - bind-mounts your MUSIC LIBRARY (read-mostly bulk media; the exFAT SD is fine
#     for this) at /opt/navidrome/music,
#   - writes a self-contained Caddy site block for music.${DOMAIN} to
#     /etc/caddy/apps/navidrome.caddy (the core Caddyfile imports
#     /etc/caddy/apps/*.caddy) and validates it fail-closed,
#   - supervises the Navidrome binary on loopback 127.0.0.1:9123 with a FAIL-CLOSED
#     loopback assert (Navidrome DEFAULTS to 0.0.0.0 — see the security note below).
#
# Auth model — gate the browser UI, EXEMPT the API: by DEFAULT, music.${DOMAIN} is
# gated at the Cloudflare edge (Cloudflare Access) and Navidrome keeps its OWN
# native login. BUT Subsonic clients (DSub/Symfonium/play:Sub/Feishin/…) hit
# /rest/* with the app's own token auth and CANNOT follow a 302-to-login, and
# public share links hit /share/* anonymously — so the vhost reverse_proxies
# /rest/* and /share/* DIRECTLY (never gated), and only the catch-all (the web UI)
# is eligible for the optional Matrix-SSO forward_auth gate. You must likewise
# EXEMPT /rest/* and /share/* in your Cloudflare Access policy (or use a service
# token) or those clients break. See the closing notes + docs/APP_AUTH.md.
#
# SCOPE — direct-play by default: ffmpeg is intentionally NOT installed, so there is
# NO on-the-fly transcoding (clients stream the original files). The scan schedule
# is conservative (@every 24h) and the FIRST scan of a large library is heavy
# (CPU + I/O on the phone). Enabling transcoding is the documented opt-in heavy
# path — see the closing notes.
#
# Idempotent + re-runnable. Generalized from the memos/vaultwarden app pattern;
# review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_NAVIDROME=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Navidrome version + sha256 rather than tracking "latest", so the
# download fails closed on any corruption/tampering. Both are env-overridable
# (and centrally pinned in config/versions.env) without editing this file.
#
# To upgrade: bump NAVIDROME_VER and NAVIDROME_SHA256 *together* (get the new hash
# from the release checksums.txt, or by hashing a tarball you already trust:
#   sha256sum navidrome_<ver>_linux_arm64.tar.gz
# ), then re-run this script. Navidrome's data (db + cache) persists across
# upgrades because it lives on $HOME/.pocket/navidrome.
NAVIDROME_VER="${NAVIDROME_VER:-0.62.0}"
NAVIDROME_SHA256="${NAVIDROME_SHA256:-842ed7f70c0dcfd85ef08427241c1327b13af9d025b43d0cedcd8c7e2c6b35b5}"
NAVIDROME_ARCH="arm64"
NAVIDROME_TARBALL="navidrome_${NAVIDROME_VER}_linux_${NAVIDROME_ARCH}.tar.gz"
NAVIDROME_URL="${NAVIDROME_URL:-https://github.com/navidrome/navidrome/releases/download/v${NAVIDROME_VER}/${NAVIDROME_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
ND_PORT="${NAVIDROME_PORT:-9123}"        # loopback bind; only Caddy reaches it
ND_HOST="music.${DOMAIN}"                # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/navidrome               # in userland — the binary + resources/
BIN="${INSTALL_DIR}/navidrome"           # in userland — /opt/navidrome/navidrome
DATA_MOUNT="${INSTALL_DIR}/data"         # in userland — ND_DATAFOLDER (bind target)
MUSIC_MOUNT="${INSTALL_DIR}/music"       # in userland — ND_MUSICFOLDER (bind target)

# ── Storage tiers ─────────────────────────────────────────────────────────────
# DB + WAL + artwork/transcode cache + index → EXT4 (NEVER exFAT). The read-mostly
# bulk music library MAY live on the exFAT SD (it is large + only read by scans /
# streaming, no fsync-critical writes). NAVIDROME_MUSIC_DIR defaults to
# ${DATA_DIR}/music; point it at wherever your library actually lives.
DATA_BACKING="${HOME}/.pocket/navidrome"           # on ext4 (host) — survives a rootfs rebuild
MUSIC_BACKING="${NAVIDROME_MUSIC_DIR:-${DATA_DIR}/music}"   # bulk media (exFAT SD ok)
CACHE_DIR="${DATA_DIR}/binaries"
NAVIDROME_LOCAL="${CACHE_DIR}/${NAVIDROME_TARBALL}"

# ── Data dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ───────────────────
# The SQLite DB (navidrome.db) + its -wal/-shm need real fsync + atomic rename +
# POSIX locks; the artwork/transcode cache + scan index live here too. exFAT can
# silently corrupt all of that. Refuse it the same way vaultwarden.sh does.
case "${DATA_BACKING}" in
  "${DATA_DIR}"|"${DATA_DIR}/"*)
    die "refusing to put the Navidrome DATA_FOLDER under DATA_DIR (${DATA_DIR}) — it is exFAT and would corrupt the SQLite DB + WAL + cache; it must stay on ext4 at \$HOME/.pocket/navidrome" ;;
esac
mkdir -p "${DATA_BACKING}" "${CACHE_DIR}" || die "cannot create ${DATA_BACKING} on ext4"
chmod 700 "${DATA_BACKING}" 2>/dev/null || true

# The music library backing dir: create it if missing (so a fresh install does not
# fail), but it MAY legitimately be on the exFAT SD — that is fine for read-mostly
# bulk media, so we do NOT refuse DATA_DIR here.
mkdir -p "${MUSIC_BACKING}" 2>/dev/null \
  || warn "could not create the music dir ${MUSIC_BACKING} — make sure it exists + is readable before first scan"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Download the release tarball, sha256-verified fail-closed ─────────────
# fetch_verified (from common.sh) reuses a cached copy that already matches the
# pin, and deletes + aborts on any mismatch.
fetch_verified "${NAVIDROME_URL}" "${NAVIDROME_LOCAL}" "${NAVIDROME_SHA256}"
ok "Navidrome v${NAVIDROME_VER} tarball ready at ${NAVIDROME_LOCAL} ($(wc -c < "${NAVIDROME_LOCAL}") bytes)"

# ── 2. Extract the binary (+ resources/) into the userland + verify it runs ──
# proot-distro manages the rootfs path, so go through `proot-distro login` and
# stream the tarball in over stdin (no hardcoded rootfs location). The release
# tarball's top level contains the `navidrome` binary + a resources/ dir.
say "extracting Navidrome into the userland (${INSTALL_DIR})"
in_debian "mkdir -p ${INSTALL_DIR}"
proot-distro login debian -- bash -lc "tar -xzf - -C ${INSTALL_DIR} && chmod +x ${BIN}" \
  < "${NAVIDROME_LOCAL}" || die "failed to extract the Navidrome binary into the userland"
in_debian "[ -x ${BIN} ]" || die "Navidrome binary missing after extract at ${BIN}"
ver="$(in_debian "${BIN} --version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "Navidrome: ${ver}" || warn "navidrome --version produced no output (continuing; the supervisor will surface a real boot failure)"

# ── 3. Bind-mount targets in the userland (data on ext4, music on the SD) ─────
in_debian "mkdir -p ${DATA_MOUNT} ${MUSIC_MOUNT}" \
  || die "failed to create the ${DATA_MOUNT}/${MUSIC_MOUNT} mountpoints in the userland"
ok "data backing ${DATA_BACKING} (ext4) → ${DATA_MOUNT}; music ${MUSIC_BACKING} → ${MUSIC_MOUNT} (bound at start time)"

# ── 4. Caddy vhost → /etc/caddy/apps/navidrome.caddy (validate fail-closed) ──
# A self-contained site block so enabling Navidrome never requires hand-editing the
# core Caddyfile (it imports /etc/caddy/apps/*.caddy). The listener style MUST
# match the other vhosts: explicit `http://<host>:${CADDY_PORT}` + `bind
# ${CADDY_BIND}` (plain HTTP on the shared high loopback port; the Cloudflare
# Tunnel terminates public TLS). The explicit http:// scheme stops Caddy inferring
# HTTPS-on-:443, which an unprivileged proot Caddy cannot bind.
#
# GATE-THE-UI / EXEMPT-THE-API: /rest/* (Subsonic clients, token auth) and /share/*
# (anonymous public share links) are reverse_proxied DIRECTLY, BEFORE the gateable
# catch-all, so they are never subject to the interactive forward_auth 302 (which
# those non-browser callers cannot follow). The optional Matrix-SSO gate, when
# uncommented, covers ONLY the catch-all (the web UI). Mirror this in Cloudflare
# Access too (exempt /rest/* and /share/*) — see the closing notes.
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, and ${ND_PORT}.
say "writing the Navidrome vhost to /etc/caddy/apps/navidrome.caddy in the userland"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/navidrome.caddy' <<EOF
# music.${DOMAIN} — Navidrome (music streaming, Subsonic-compatible).
# Written by scripts/apps/navidrome.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here and (by default) Cloudflare Access gates the web UI
# at the edge — but you MUST EXEMPT /rest/* and /share/* there too (Subsonic apps
# use token auth + public links are anonymous; neither can do a 302 login). See
# docs/APP_AUTH.md.
http://music.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# ── EXEMPT API paths (NEVER gated) ──────────────────────────────────────────
	# Subsonic clients authenticate with their OWN token on /rest/* and CANNOT
	# follow an interactive 302; public share links on /share/* are anonymous.
	# These handle blocks reverse_proxy straight to the backend and MUST come
	# BEFORE the gateable catch-all below. Navidrome's own token/share auth (and a
	# CF Access service-token exemption) protects them.
	handle /rest/* {
		reverse_proxy 127.0.0.1:${ND_PORT}
	}
	handle /share/* {
		reverse_proxy 127.0.0.1:${ND_PORT}
	}

	# ── Browser web UI (gateable) ───────────────────────────────────────────────
	handle {
		# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md).
		# By default this stays COMMENTED OUT: the hostname is gated by Cloudflare
		# Access at the edge and Navidrome keeps its own native login. To front the
		# WEB UI with the Matrix-SSO gateway instead, run that add-on and uncomment
		# the three parts below — they MUST precede the catch-all reverse_proxy and
		# they ONLY cover this web-UI handle (NOT /rest/* or /share/* above, which
		# must stay ungated for Subsonic clients + share links). The /authgw/*
		# handler keeps the login form reachable (else the 302-to-login loops), the
		# request_header strips any client-forged Remote-User before the gate, and
		# forward_auth then gates everything else:
		#
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

		# Web UI + native API → the Navidrome backend on loopback.
		reverse_proxy 127.0.0.1:${ND_PORT}
	}
}
EOF
then
  die "failed to write /etc/caddy/apps/navidrome.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so
# we never leave a broken edge config in place.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/navidrome.caddy"
ok "Navidrome vhost written + Caddyfile validates"

# NOTE: we do NOT restart Caddy here. During a full install the stack is started
# afterward (scripts/start-stack.sh). If the stack is ALREADY running, the new
# vhost is not live until Caddy reloads — see the closing notes.

# ── 5. FAIL-CLOSED loopback guard ────────────────────────────────────────────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ Navidrome's Address option DEFAULTS to 0.0.0.0 (verified in upstream
# │ conf/configuration.go: viper.SetDefault("address", "0.0.0.0")). proot shares
# │ the host network namespace, so 0.0.0.0 would expose the music server on the
# │ phone's REAL Wi-Fi/cell interfaces — a verified past-outage class. We force
# │ loopback via ND_ADDRESS=127.0.0.1 on the launch env (step 6) and additionally
# │ refuse to start unless the env we are about to pass is exactly 127.0.0.1. We
# │ pass config via ND_* ENV (not a config file), so the guard checks the value we
# │ are about to launch with rather than grepping a file.
# └────────────────────────────────────────────────────────────────────────────
ND_ADDRESS_VALUE="127.0.0.1"
case "${ND_ADDRESS_VALUE}" in
  127.0.0.1) : ;;
  *) die "ND_ADDRESS is '${ND_ADDRESS_VALUE}', not 127.0.0.1 — refusing to start a LAN-exposed music server (Navidrome defaults to 0.0.0.0)" ;;
esac
ok "Navidrome bind confirmed loopback (ND_ADDRESS=${ND_ADDRESS_VALUE})"

# ── 6. Supervise Navidrome on loopback ───────────────────────────────────────
# Navidrome reads ND_* env (prefix ND, '.'→'_' replacer — confirmed upstream).
#   ND_ADDRESS=127.0.0.1   → loopback only (overrides the 0.0.0.0 default).
#   ND_PORT=${ND_PORT}     → loopback port Caddy reverse_proxies to.
#   ND_DATAFOLDER          → db + cache on the ext4 bind (NEVER exFAT).
#   ND_MUSICFOLDER         → the bulk library bind (exFAT SD ok; read-mostly).
#   ND_SCANNER_SCHEDULE    → conservative @every 24h (Scanner.Schedule). The FIRST
#                            scan of a large library is heavy; "0" disables it.
# Two bind-mounts at launch: ext4 data → ${DATA_MOUNT}, library → ${MUSIC_MOUNT}.
# The shared supervisor respawns it on crash with an identity-checked pidfile and
# records the exact argv (incl. both binds) to ${name}.cmd for drift-free restart.
say "supervising Navidrome (Go binary in the userland, bind 127.0.0.1:${ND_PORT})"
supervise navidrome -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  --bind "${MUSIC_BACKING}:${MUSIC_MOUNT}" \
  -- env ND_ADDRESS="${ND_ADDRESS_VALUE}" ND_PORT="${ND_PORT}" \
         ND_DATAFOLDER="${DATA_MOUNT}" ND_MUSICFOLDER="${MUSIC_MOUNT}" \
         ND_SCANNER_SCHEDULE='@every 24h' \
         "${BIN}"

# ── 7. Best-effort health check ──────────────────────────────────────────────
# Navidrome serves GET /ping → 200 (chi middleware.Heartbeat("/ping"), confirmed
# upstream). The Go binary + proot cold start can take a few seconds; poll the
# loopback port. A non-200 here is a WARNING (the supervisor keeps retrying), not
# fatal.
say "waiting for Navidrome to answer on 127.0.0.1:${ND_PORT}"
healthy=0
for _ in $(seq 1 40); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${ND_PORT}/ping" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Navidrome healthy on 127.0.0.1:${ND_PORT} (/ping)"
else
  warn "Navidrome not yet answering on :${ND_PORT}/ping — check ${POCKET_LOG_DIR}/navidrome.log (the supervisor keeps retrying; a big first scan can delay readiness)"
fi

# ── 8. Closing notes (manual Cloudflare + scope) ─────────────────────────────
cat >&2 <<EOF

$(ok "Navidrome installed + supervised on 127.0.0.1:${ND_PORT} (data on ${DATA_BACKING}, music ${MUSIC_BACKING})" 2>&1)

  FIRST RUN: open music.${DOMAIN} and create the first admin account immediately
  (the FIRST visitor becomes the admin — do this before exposing it publicly).
  The first library scan of ${MUSIC_BACKING} runs in the background and can be
  heavy (CPU + I/O) on a phone; the schedule afterward is conservative (@every 24h).

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${ND_HOST}  ->  http://localhost:${CADDY_PORT}
       (plain HTTP — the tunnel terminates public TLS).
    2. Cloudflare Access — GATE THE UI, EXEMPT THE API: add an Access application
       for ${ND_HOST} to gate the web UI, but you MUST also add path-based
       BYPASS/exemption (or a SERVICE TOKEN) for:
         /rest/*    (Subsonic clients — DSub / Symfonium / play:Sub / Feishin …)
         /share/*   (anonymous public share links)
       Those callers use Navidrome's own token / share auth and CANNOT complete an
       interactive Access login redirect — without the exemption they break. The
       vhost already reverse_proxies /rest/* and /share/* without the SSO gate.
       See docs/APP_AUTH.md.

  SCOPE — direct-play by default: ffmpeg is NOT installed, so streaming is
  direct-play (no on-the-fly transcoding). To enable transcoding (the OPT-IN heavy
  path), install ffmpeg in the userland (proot-distro login debian -- apt-get
  install -y ffmpeg) and configure a transcoding profile in Navidrome's settings.
  This is CPU-intensive on a phone — leave it off unless you need it.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).

  Optional Matrix-SSO gateway add-on: see the commented forward_auth block in
  /etc/caddy/apps/navidrome.caddy (it gates ONLY the web-UI handle, never /rest or
  /share) and docs/APP_AUTH.md.
EOF

ok "apps/navidrome.sh done (music.${DOMAIN} once the Cloudflare hostname + Access policy + /rest,/share exemption are added)"

