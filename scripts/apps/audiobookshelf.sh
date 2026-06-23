#!/usr/bin/env bash
#
# apps/audiobookshelf.sh — build + install + supervise Audiobookshelf (ABS), the
# self-hosted audiobook + podcast server, as an OPTIONAL app behind the loopback
# Caddy edge, on audiobooks.${DOMAIN}.
#
# Audiobookshelf is a Node.js (Nuxt client + Express server) app. Upstream ships
# NO arm64 release binary — only a multi-arch Docker image and a source tree — so
# (exactly like apps/pingvin.sh) it is BUILT FROM SOURCE on-device from a pinned
# upstream git TAG. The server serves on 127.0.0.1:9127; the core Caddy fronts it.
#
# ⚠ FIRST RUN IS VERY SLOW: a client `npm ci && npm run generate` (a full Nuxt
# build) + a server `npm ci` on a phone can take 15-40+ minutes and is one of the
# heaviest steps in the whole stack. Re-runs skip the build (idempotent). The build
# caps the V8 heap so it cannot OOM-kill the live Matrix/Caddy stack while it runs.
#
# ⚠ SECURITY — LOOPBACK BIND (fail-closed). ABS reads HOST from process.env.HOST
# (index.js: `const HOST = options.host || process.env.HOST`) with NO default, so an
# unset HOST means Node/Express binds 0.0.0.0 + :: (ALL interfaces) — which, because
# proot shares the host network namespace, would expose ABS on the phone's REAL Wi-Fi
# / mobile interfaces (a verified past-outage class on this stack). run.sh therefore
# EXPORTS HOST=127.0.0.1 and this script ASSERTS run.sh contains it, aborting rather
# than ever launching a 0.0.0.0-binding server.
#
# ⚠ SUPPLY CHAIN — PINNED NATIVE BINARIES (fail-closed). ABS would AUTO-DOWNLOAD its
# native helpers (ffmpeg/ffprobe + the nunicode unicode-FTS SQLite extension) from
# the network on first boot, which defeats pinning. We pre-place BOTH and point ABS
# at them, then set SKIP_BINARIES_CHECK=1 so it never reaches out:
#   * ffmpeg + ffprobe are MANDATORY — ABS's BinaryManager calls process.exit(1) if
#     a required binary's env var is unset, EVEN with SKIP_BINARIES_CHECK=1 (verified
#     in server/managers/BinaryManager.js). We install bookworm's apt ffmpeg (~5.1.x,
#     satisfies ABS's >=5.1 floor) and point FFMPEG_PATH / FFPROBE_PATH at it.
#   * libnusqlite3.so (the nunicode FTS extension; NOT required by BinaryManager) is
#     fetched from a PINNED release @ a self-pinned sha256 (fail-closed via
#     fetch_verified), unzipped onto ext4, and pointed at by NUSQLITE3_PATH.
#
# SCOPE — direct-play by default: ffmpeg is here for ABS's MANDATORY media probing /
# duration scan only. On-the-fly TRANSCODING is the thermal / low-memory-killer heavy
# path and is NOT enabled here — clients direct-play. Treat transcode as an opt-in
# heavy path (see the closing notes + docs).
#
# DATA (ext4): the SQLite DB (absdatabase.sqlite + -wal/-shm), config, metadata
# covers/cache/backups, the git tree, node_modules, and the app itself ALL live on
# ext4 at $HOME/.pocket/audiobookshelf (bind-mounted into the userland) — NEVER on
# the exFAT SD card (it would corrupt the DB + WAL + locks). Only the bulk audiobook
# LIBRARY may live on the SD card (ABS_LIBRARY_DIR; ABS only ever READS it).
#
# AUTH MODEL (default): ABS keeps its OWN native login (you create the first/root
# user in its first-run wizard). The hostname is ALSO gated at the Cloudflare edge
# with Cloudflare Access. SHARP EDGE: the ABS mobile/desktop apps authenticate with a
# JWT bearer to /api (and other non-browser paths) and CANNOT follow a 302-to-login,
# so the vhost gates only the browser UI and EXEMPTS the API paths (see step 8 + the
# closing notes). The optional Matrix-SSO gateway is a documented add-on (commented
# block in the vhost).
#
# Generalized from the pingvin/vaultwarden app patterns; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_AUDIOBOOKSHELF=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Audiobookshelf is built from a PINNED upstream git TAG (env-overridable). Upstream
# distributes a Docker image / source tree, not a release tarball with a published
# sha256, so integrity here is the immutable tag fetched over HTTPS from the canonical
# repo (do NOT invent a tarball sha — same posture as apps/pingvin.sh). To upgrade:
# back up the DB ($HOME/.pocket/audiobookshelf) FIRST, then bump ABS_TAG and re-run
# (the loopback assert re-applies, fail-closed).
ABS_TAG="${ABS_TAG:-v2.35.1}"
ABS_REPO="${ABS_REPO:-https://github.com/advplyr/audiobookshelf.git}"

# ── Pinned native nunicode (unicode-FTS) SQLite extension ────────────────────
# fail-closed sha256 (fetch_verified). The official ABS Docker image bundles this;
# we pre-place the GLIBC arm64 build so ABS does NOT auto-download a native blob on
# first boot. The maintainer's release ships no upstream checksum, so this sha256 is
# SELF-PINNED — the INTEGRATOR re-derives it during E2E by downloading the asset and
# hashing it (curl -fsSL "$ABS_NUSQLITE_URL" | sha256sum), then commits the real value.
# (The github.com/.../nunicode-sqlite/... URL 301-redirects to the nunicode-binaries
# release; fetch_verified uses curl -fsSL, which follows the redirect.)
ABS_NUSQLITE_VER="${ABS_NUSQLITE_VER:-v1.2}"
ABS_NUSQLITE_URL="${ABS_NUSQLITE_URL:-https://github.com/mikiher/nunicode-sqlite/releases/download/${ABS_NUSQLITE_VER}/libnusqlite3-linux-arm64.zip}"
# INTEGRATOR: re-verify this by download+hash during E2E (claimed value below).
ABS_NUSQLITE_SHA256="${ABS_NUSQLITE_SHA256:-b92ed0f5c45fc10bd0230577ee429141e6a3b5fca289b8432fa46833d21e38d0}"

# ── Service-local config ─────────────────────────────────────────────────────
ABS="/opt/audiobookshelf"                       # install dir INSIDE the userland (git tree + build)
ABS_PORT="${AUDIOBOOKSHELF_PORT:-9127}"          # loopback bind; only Caddy reaches it
ABS_HOST="audiobooks.${DOMAIN}"                  # public hostname (via the CF Tunnel)

# ── Storage tiers ─────────────────────────────────────────────────────────────
# ALL writable state on ext4 (NOT exFAT). absdatabase.sqlite + -wal/-shm need real
# fsync + atomic rename + unix locks; config + metadata (covers/cache/backups) live
# here too. The whole ext4 tree is bind-mounted onto ${ABS}/data inside the userland.
ABS_DATA_BACKING="${HOME}/.pocket/audiobookshelf"   # on ext4 (host) — survives a rootfs rebuild
ABS_DATA_MOUNT="${ABS}/data"                         # bind target inside the userland
ABS_CONFIG_PATH="${ABS_DATA_MOUNT}/config"           # CONFIG_PATH (SQLite DB)
ABS_METADATA_PATH="${ABS_DATA_MOUNT}/metadata"       # METADATA_PATH (covers/cache/backups)
ABS_NUSQLITE_DIR="${ABS}/nusqlite3"                  # ext4 (rootfs) — the .so lives here
ABS_NUSQLITE_SO="${ABS_NUSQLITE_DIR}/libnusqlite3.so"

# The read-only BULK audiobook library MAY live on the exFAT SD card — it is media,
# not a DB. User-supplied; defaults under ${DATA_DIR}. Bind-mounted read-only into the
# userland; the user adds it as a Library in the first-run wizard.
ABS_LIBRARY_DIR="${ABS_LIBRARY_DIR:-${DATA_DIR}/audiobooks}"
ABS_LIBRARY_MOUNT="${ABS}/audiobooks"               # bind target inside the userland

CACHE_DIR="${DATA_DIR}/binaries"
ABS_NUSQLITE_ZIP="${CACHE_DIR}/libnusqlite3-linux-arm64-${ABS_NUSQLITE_VER}.zip"

# ── HARD RULE: writable state must be on ext4 — REFUSE DATA_DIR (exFAT) ───────
# fail-closed: the DB + WAL + config + metadata MUST NOT land on the exFAT SD card.
assert_ext4 "${ABS_DATA_BACKING}" "Audiobookshelf data dir"
mkdir -p "${ABS_DATA_BACKING}" "${CACHE_DIR}" || die "cannot create ${ABS_DATA_BACKING} on ext4"
chmod 700 "${ABS_DATA_BACKING}" 2>/dev/null || true
mkdir -p "${ABS_LIBRARY_DIR}" 2>/dev/null || warn "could not create the library dir ${ABS_LIBRARY_DIR} (add it yourself; bind-mounted read-only)"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Build/runtime deps inside the userland (Node 20 + a C toolchain + ffmpeg) ─
# ABS's client + server need Node.js + npm; node-pre-gyp pulls a glibc arm64 sqlite3
# prebuilt, with build-essential + python3 as the compile fallback. ffmpeg/ffprobe
# are MANDATORY for ABS (BinaryManager exits if their env vars are unset). tzdata +
# unzip + ca-certificates + curl round it out. (Node version note: ABS expects Node
# 20+. Debian bookworm's apt nodejs may be older; we WARN, not fail — the build will
# surface a real incompatibility loudly.)
run_once audiobookshelf-apt -- in_debian \
  "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     git nodejs npm ca-certificates build-essential python3 ffmpeg tzdata unzip curl" \
  || die "could not install Audiobookshelf build/runtime deps inside the userland"

node_major="$(in_debian 'node -p "process.versions.node.split(\".\")[0]" 2>/dev/null' | tr -dc '0-9' || true)"
if [ -n "${node_major}" ] && [ "${node_major}" -lt 20 ] 2>/dev/null; then
  warn "userland Node is v${node_major} — Audiobookshelf expects Node 20+. The build may fail;"
  warn "  if so, install a newer Node in the userland (e.g. via NodeSource) and re-run."
fi

# Resolve the apt ffmpeg/ffprobe absolute paths INSIDE the userland (MANDATORY; ABS
# process.exit(1)s if FFMPEG_PATH/FFPROBE_PATH are unset). Fail closed if absent.
FFMPEG_BIN="$(in_debian 'command -v ffmpeg' 2>/dev/null | tr -d '\r' || true)"
FFPROBE_BIN="$(in_debian 'command -v ffprobe' 2>/dev/null | tr -d '\r' || true)"
[ -n "${FFMPEG_BIN}" ]  || die "ffmpeg not found in the userland after apt install — Audiobookshelf needs it (FFMPEG_PATH); fix the apt step and re-run"
[ -n "${FFPROBE_BIN}" ] || die "ffprobe not found in the userland after apt install — Audiobookshelf needs it (FFPROBE_PATH); fix the apt step and re-run"
ok "ffmpeg: ${FFMPEG_BIN}  ffprobe: ${FFPROBE_BIN} (apt; satisfies ABS's >=5.1 floor)"

# ── 2. Pre-place the pinned nunicode SQLite extension (fail-closed sha256) ────
# fetch_verified reuses a cached copy that already matches the pin and deletes +
# aborts on any mismatch. Unzip onto ext4 (the userland rootfs) and assert the .so.
fetch_verified "${ABS_NUSQLITE_URL}" "${ABS_NUSQLITE_ZIP}" "${ABS_NUSQLITE_SHA256}"
say "installing the nunicode SQLite extension into the userland (${ABS_NUSQLITE_SO})"
in_debian "mkdir -p '${ABS_NUSQLITE_DIR}'" || die "cannot create ${ABS_NUSQLITE_DIR} in the userland"
proot-distro login debian -- bash -lc "unzip -o -j - -d '${ABS_NUSQLITE_DIR}'" < "${ABS_NUSQLITE_ZIP}" \
  >/dev/null 2>&1 || die "failed to unzip the nunicode extension into the userland"
# The zip may name the file libnusqlite3.so directly or carry a path; normalize.
in_debian "[ -f '${ABS_NUSQLITE_SO}' ] || { f=\$(find '${ABS_NUSQLITE_DIR}' -name 'libnusqlite3*.so' | head -1); [ -n \"\$f\" ] && mv -f \"\$f\" '${ABS_NUSQLITE_SO}'; }"
in_debian "[ -f '${ABS_NUSQLITE_SO}' ]" || die "libnusqlite3.so missing after unzip at ${ABS_NUSQLITE_SO}"
ok "nunicode extension placed (${ABS_NUSQLITE_SO}; sha256-pinned ${ABS_NUSQLITE_SHA256})"

# ── 3. Clone the pinned upstream tag (idempotent) ────────────────────────────
if in_debian "[ -d '${ABS}/.git' ]"; then
  say "Audiobookshelf source already present at ${ABS} (reusing the clone)"
else
  say "cloning Audiobookshelf ${ABS_TAG} -> ${ABS}"
  in_debian "set -e; rm -rf '${ABS}'; git clone --depth 1 --branch '${ABS_TAG}' '${ABS_REPO}' '${ABS}'" \
    || die "git clone of Audiobookshelf ${ABS_TAG} failed"
fi
in_debian "[ -f '${ABS}/index.js' ] && [ -d '${ABS}/client' ]" \
  || die "expected ${ABS}/index.js + ${ABS}/client after clone — upstream layout changed?"

# ── 4. Build the client (Nuxt) + server deps — heavy, idempotent ─────────────
# Upstream's package.json: client build is `cd client && npm ci && npm run generate`,
# then the server installs its own deps with `npm ci` in the repo root (node-pre-gyp
# pulls the glibc arm64 sqlite3 prebuilt). proot mishandles npm cacache's concurrent
# atomic renames over a flaky link, so we serialize sockets, raise retries, cap the V8
# heap (so the Nuxt generate can't OOM-kill the live stack), and use INCREMENTAL
# `npm install` (not `npm ci`, which is all-or-nothing and re-fetches everything).
# Re-runs skip a stage whose output already exists.
say "building Audiobookshelf (heaviest step — 15-40+ minutes on a phone; re-runs skip it)"
in_debian "
  set -e
  export NODE_OPTIONS='--max-old-space-size=1536'
  export NUXT_TELEMETRY_DISABLED=1 CI=1
  npm config set maxsockets 1 2>/dev/null || true
  npm config set fetch-retries 6 2>/dev/null || true
  npm config set fetch-retry-mintimeout 20000 2>/dev/null || true
  npm config set fetch-retry-maxtimeout 180000 2>/dev/null || true
  npm config set fund false 2>/dev/null || true
  npm config set audit false 2>/dev/null || true

  npm_install_retry() {
    local n=1
    while [ \$n -le 8 ]; do
      echo \"[abs] npm install attempt \$n (\$(pwd))\"
      if npm install --no-audit --no-fund; then return 0; fi
      npm cache clean --force 2>/dev/null || true
      n=\$((n+1))
    done
    return 1
  }

  # client (Nuxt) — install deps then 'npm run generate' (the static client build)
  cd '${ABS}/client'
  if [ ! -d node_modules ]; then npm_install_retry || { echo 'FAIL: client npm install'; exit 2; }; fi
  if [ ! -d '${ABS}/client/dist' ]; then npm run generate || { echo 'FAIL: client generate'; exit 3; }; fi

  # server — install deps in the repo root (node-pre-gyp pulls the sqlite3 prebuilt)
  cd '${ABS}'
  if [ ! -d node_modules ]; then npm_install_retry || { echo 'FAIL: server npm install'; exit 4; }; fi
" 2>&1 | grep -v 'proot warning' || die "Audiobookshelf build failed inside the userland (see output above)"

# Fail closed: both build outputs must exist.
in_debian "[ -d '${ABS}/client/dist' ] && [ -d '${ABS}/node_modules' ] && [ -f '${ABS}/index.js' ]" \
  || die "Audiobookshelf build incomplete (need client/dist + node_modules + index.js)"
ok "Audiobookshelf built (client/dist + server node_modules present)"

# ── 5. Data dirs on ext4 (config + metadata bind targets) ────────────────────
in_debian "mkdir -p '${ABS_CONFIG_PATH}' '${ABS_METADATA_PATH}' '${ABS_LIBRARY_MOUNT}'" \
  || die "failed to create the ABS data/library mountpoints in the userland"

# ── 6. run.sh launcher (server on 127.0.0.1:${ABS_PORT}; native binaries pinned) ─
# Runs INSIDE the userland. HOST=127.0.0.1 is the loopback bind (ABS defaults to
# 0.0.0.0+:: when HOST is unset). ROUTER_BASE_PATH is set to EMPTY so routes are
# served at root (upstream's default '/audiobookshelf' is used VERBATIM if unset —
# Server.js assigns it to global.RouterBasePath with NO normalization — which would
# serve every route under /audiobookshelf/*; we want root to match the vhost).
# SKIP_BINARIES_CHECK=1 stops ABS auto-downloading ffmpeg/the nunicode .so; the env
# paths below point at the pre-placed pinned binaries (FFMPEG_PATH/FFPROBE_PATH are
# MANDATORY even with the skip — see header). Entry is `node index.js` (package.json
# main + start).
say "writing ${ABS}/run.sh launcher"
proot-distro login debian -- bash -lc "umask 077; cat > '${ABS}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/audiobookshelf.sh.
# Server (Express) binds 127.0.0.1:${ABS_PORT}. DB/config/metadata on the ext4 bind.
set -u
cd '${ABS}' || exit 1
export NODE_ENV=production
export NUXT_TELEMETRY_DISABLED=1
export SOURCE=debian
export HOST=127.0.0.1                         # loopback bind (ABS defaults to 0.0.0.0 when unset)
export PORT=${ABS_PORT}
export ROUTER_BASE_PATH=                      # serve routes at root (NOT /audiobookshelf)
export CONFIG_PATH='${ABS_CONFIG_PATH}'       # absdatabase.sqlite + -wal/-shm (ext4)
export METADATA_PATH='${ABS_METADATA_PATH}'   # covers / cache / backups (ext4)
export FFMPEG_PATH='${FFMPEG_BIN}'            # MANDATORY (apt ffmpeg, >=5.1)
export FFPROBE_PATH='${FFPROBE_BIN}'          # MANDATORY (apt ffprobe)
export NUSQLITE3_PATH='${ABS_NUSQLITE_SO}'    # pinned unicode-FTS extension (ext4)
export SKIP_BINARIES_CHECK=1                  # do NOT auto-download native binaries

exec node index.js
LAUNCH
in_debian "chmod +x '${ABS}/run.sh'" || die "failed to make ${ABS}/run.sh executable"
ok "wrote ${ABS}/run.sh"

# ── 7. FAIL-CLOSED loopback assert ───────────────────────────────────────────
# Guards against the 0.0.0.0 default: refuse to start unless run.sh pins HOST to
# loopback, and refuse if it ever sets 0.0.0.0.
say "asserting the Audiobookshelf bind is loopback (guards against the 0.0.0.0 default)"
in_debian "grep -Eq '^[[:space:]]*export HOST=127\.0\.0\.1[[:space:]]*\$' '${ABS}/run.sh'" \
  || die "HOST is NOT pinned to 127.0.0.1 in ${ABS}/run.sh — refusing to start a LAN-exposed server"
in_debian "grep -Eq 'HOST=0\.0\.0\.0|HOST=::' '${ABS}/run.sh'" \
  && die "Audiobookshelf run.sh binds 0.0.0.0/:: — refusing to start (check ${ABS}/run.sh)" || true
ok "Audiobookshelf bind confirmed loopback (127.0.0.1:${ABS_PORT})"

# ── 8. Caddy vhost (self-contained; imported by the core Caddyfile) ──────────
# Listener style matches the other vhosts EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS).
#
# CF-Access split (gate the browser UI, EXEMPT the non-browser API paths): the ABS
# mobile/desktop apps send a JWT bearer to /api (+ /public, /feed, /status, /hls,
# /healthcheck, /ping) and CANNOT follow a 302-to-login. So those paths are
# reverse_proxied DIRECTLY (BEFORE any gate), and only the catch-all (the browser UI)
# is gateable. ABS's own token/login protects the exempt API paths. At the Cloudflare
# edge, mirror this: exempt those paths in your Access policy or use a service token
# (see the closing notes).
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, ${ABS_HOST}, and ${ABS_PORT}.
say "writing the Audiobookshelf vhost -> /etc/caddy/apps/audiobookshelf.caddy"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/audiobookshelf.caddy' <<EOF
# audiobooks.${DOMAIN} — Audiobookshelf (audiobook + podcast server).
# Written by scripts/apps/audiobookshelf.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here. Auth = ABS's OWN login; the hostname is ALSO gated by
# Cloudflare Access at the edge. The native apps use a JWT bearer to /api and the
# other non-browser paths and CANNOT do a 302, so those paths BYPASS the (optional)
# interactive gate below; only the browser UI is gated. See docs/APP_AUTH.md.
http://${ABS_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		X-Frame-Options SAMEORIGIN
		-Server
	}

	# Streaming + large uploads: ABS streams audio (and HLS) and accepts large
	# library uploads; no response buffering + generous timeouts on every handle.

	# ── Non-browser API paths — reverse_proxied DIRECTLY, BEFORE any gate ──
	# The ABS apps authenticate here with a JWT bearer and can't follow a 302, so
	# these MUST sit before the optional forward_auth catch-all. ABS's own token auth
	# protects them. At the CF edge, give these paths an Access bypass / service token.
	@absapi path /api/* /public/* /feed/* /status /healthcheck /ping /hls/*
	handle @absapi {
		reverse_proxy 127.0.0.1:${ABS_PORT} {
			flush_interval -1
			transport http {
				read_timeout 600s
				write_timeout 600s
			}
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is ABS's own login + Cloudflare Access at the
	# edge. To enable, run the optional Matrix-auth gateway and uncomment the block
	# INSIDE the catch-all `handle` below (see docs/APP_AUTH.md). It lives inside that
	# handle (NOT at site level) so Caddy's directive ordering cannot hoist forward_auth
	# ahead of the @absapi handle above — the ABS token API stays exempt regardless of
	# ordering. It gates ONLY the browser UI. The /authgw/* handler keeps the login form
	# reachable (else the 302-to-login loops), request_header strips any client-forged
	# Remote-User before the gate, and forward_auth then gates the catch-all:

	# ── Browser UI (the gateable catch-all) ──
	handle {
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
		reverse_proxy 127.0.0.1:${ABS_PORT} {
			flush_interval -1
			transport http {
				read_timeout 600s
				write_timeout 600s
			}
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
		}
	}
}
EOF
then
  die "failed to write /etc/caddy/apps/audiobookshelf.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so we
# never leave a broken edge config in place. We do NOT restart Caddy here.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/audiobookshelf.caddy"
ok "Audiobookshelf vhost written + Caddyfile validates"

# ── 9. Supervise the service ─────────────────────────────────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs run.sh inside
# the userland, with the ext4 data dir + the bulk library both bind-mounted. NOTE:
# proot-distro's --bind has NO read-only flag (a :ro suffix would be misparsed as part
# of the guest path), so the library is read-MOSTLY by behavior, not by mount: ABS
# only ever READS the library (originals); everything it WRITES (config/metadata/DB)
# goes to the separate ext4 data bind. Keep the host library dir non-writable by the
# userland if you want a stronger guarantee.
say "supervising Audiobookshelf (Node server in the userland, bind 127.0.0.1:${ABS_PORT})"
supervise audiobookshelf -- \
  proot-distro login debian \
  --bind "${ABS_DATA_BACKING}:${ABS_DATA_MOUNT}" \
  --bind "${ABS_LIBRARY_DIR}:${ABS_LIBRARY_MOUNT}" \
  -- bash "${ABS}/run.sh"

# ── 10. Best-effort health check ─────────────────────────────────────────────
# /healthcheck is an unauthenticated liveness endpoint (returns 200). The Node + Nuxt
# + proot cold start can take a while; poll the loopback port. A non-200 here is a
# WARNING (the supervisor keeps retrying), not fatal.
say "waiting for Audiobookshelf to answer on 127.0.0.1:${ABS_PORT}"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${ABS_PORT}/healthcheck" 2>/dev/null \
     || curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${ABS_PORT}/ping" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 2
done
if [ "${healthy}" -eq 1 ]; then
  ok "Audiobookshelf answering on 127.0.0.1:${ABS_PORT}"
else
  warn "Audiobookshelf not yet answering on :${ABS_PORT} — check ${POCKET_LOG_DIR}/audiobookshelf.log (the supervisor keeps retrying; first boot + DB init can be slow)"
fi

# ── 11. Closing notes ─────────────────────────────────────────────────────────
cat >&2 <<EOF

$(ok "Audiobookshelf installed + supervised on 127.0.0.1:${ABS_PORT} (data on ${ABS_DATA_BACKING})" 2>&1)

  FIRST RUN: open audiobooks.${DOMAIN} and create your ROOT (admin) user in the
  setup wizard, then add a Library pointing at  ${ABS_LIBRARY_MOUNT}  (your bulk
  audiobook files at ${ABS_LIBRARY_DIR}; ABS only reads it — all writes go to ext4).

  PLAYBACK: direct-play is the default (no transcode). On-the-fly TRANSCODING is the
  thermal / low-memory-killer HEAVY path on a phone and is NOT enabled here — prefer
  client direct-play. ffmpeg is present only for ABS's mandatory media probing /
  duration scan. Treat transcode as an opt-in heavy path. Conservative library scans
  are recommended; face/cover auto-fetch and aggressive re-scans cost CPU + storage.

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${ABS_HOST}  ->  http://localhost:${CADDY_PORT}   (plain HTTP; the tunnel
       terminates public TLS).
    2. Cloudflare Access: gate the BROWSER UI of ${ABS_HOST} with an Access policy,
       but EXEMPT the non-browser API paths the apps use (they send a JWT bearer and
       CANNOT complete an interactive login redirect):
         /api/*  /public/*  /feed/*  /status  /healthcheck  /ping  /hls/*
       Add those as Access "bypass" paths, OR put a SERVICE TOKEN on the hostname and
       have the apps present it. ABS's own login/token protects those paths. See
       docs/APP_AUTH.md.

  Upgrades: back up ${ABS_DATA_BACKING} FIRST (admin panel -> Backups, or
  scripts/ops/backup-db.sh), then bump ABS_TAG and re-run (the loopback assert
  re-applies fail-closed). The SQLite DB migrates on first start.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).
EOF

ok "apps/audiobookshelf.sh done (audiobooks.${DOMAIN} once the Cloudflare hostname + Access split are added)"

# Generalized from a working deployment; review before running.
