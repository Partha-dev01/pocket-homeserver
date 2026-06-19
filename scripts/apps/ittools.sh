#!/usr/bin/env bash
#
# apps/ittools.sh — install IT-Tools (CorentinTh/it-tools), a client-side
# "developer toolbox" (encoders, converters, generators, formatters, crypto
# helpers, ...), served as a STATIC site by Caddy at tools.${DOMAIN}.
#
# What it does:
#   - downloads the upstream PREBUILT release zip (pinned version + sha256 as a
#     fail-closed supply-chain check) into ${DATA_DIR}/binaries,
#   - unzips it, locates the SPA entrypoint (index.html — the release zip may
#     wrap the dist in a subdir, so we find index.html and use ITS directory),
#   - installs the dist into the userland serve root /var/www/it-tools (Caddy
#     runs inside the userland and roots its file_server there),
#   - self-hosts the figlet fonts for the ASCII-art tool and repoints the unpkg
#     CDN path to a same-origin /fonts/ path (a genuine correctness fix — see
#     step 4; non-fatal + idempotent),
#   - writes a self-contained vhost to /etc/caddy/apps/ittools.caddy and runs
#     `caddy validate` inside the userland to fail closed on a bad config.
#
# IT-Tools is a Vue 3 / Vite single-page app: every tool runs 100% in the
# browser. There is NO backend process, NO API, NO database — so there is
# nothing to supervise (build-once-then-serve, exactly like Element Web). The
# dist/ output is plain HTML/JS/CSS/wasm and ARCH-INDEPENDENT, so the prebuilt
# zip is the robust default (no on-phone toolchain needed). The heavy from-source
# pnpm build path that the reference offered is omitted here to keep this focused.
#
# Auth model: IT-Tools ships NO auth of its own. In pocket-homeserver the DEFAULT
# is to gate tools.${DOMAIN} at the edge with a Cloudflare Access policy (set in
# the Cloudflare dashboard, NOT by this script). The vhost below therefore just
# serves the static bundle; an OPTIONAL Matrix-SSO gateway forward_auth block is
# included COMMENTED OUT for those who run that add-on (see docs/APP_AUTH.md).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl
require_cmd unzip

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT IT-Tools version + sha256 rather than tracking "latest": a fixed
# hash lets us fail closed on a corrupt/tampered download. The dist is the
# arch-independent prebuilt static output, so this is the fast default (no
# on-phone Node/pnpm toolchain). All three can be overridden from the env.
# To upgrade: bump ITTOOLS_VERSION and ITTOOLS_ZIP_SHA256 *together*. Get the
# hash from a trusted copy:  sha256sum it-tools-<ver>.zip
ITTOOLS_VERSION="${ITTOOLS_VERSION:-2024.10.22-7ca5933}"
ITTOOLS_TAG="${ITTOOLS_TAG:-v${ITTOOLS_VERSION}}"
ITTOOLS_ZIP_URL="${ITTOOLS_ZIP_URL:-https://github.com/CorentinTh/it-tools/releases/download/${ITTOOLS_TAG}/it-tools-${ITTOOLS_VERSION}.zip}"
ITTOOLS_ZIP_SHA256="${ITTOOLS_ZIP_SHA256:-eef276d675db6053bdc65cd8482a566785561c70eed5035a0e05b0e627b0989d}"

# In-userland serve root that Caddy's file_server roots at.
SERVE_ROOT="/var/www/it-tools"

CACHE_DIR="${DATA_DIR}/binaries"
ZIP_LOCAL="${CACHE_DIR}/it-tools-${ITTOOLS_VERSION}.zip"
mkdir -p "${CACHE_DIR}"

# Scratch dir on the host (cleaned on exit) for unzip + figlet staging. We keep
# everything under DATA_DIR — Termux has no usable /tmp.
WORK="${CACHE_DIR}/.ittools-work-$$"
cleanup() { rm -rf "${WORK}" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "${WORK}"

# ── 1. Download the prebuilt zip to the cache (verified, fail-closed) ─────────
# fetch_verified reuses a cached copy if it already matches the pin (so this is
# safe to re-run) and deletes + aborts on any sha256 mismatch.
say "fetching prebuilt IT-Tools ${ITTOOLS_TAG} (arch-independent static dist)"
fetch_verified "${ITTOOLS_ZIP_URL}" "${ZIP_LOCAL}" "${ITTOOLS_ZIP_SHA256}"

# ── 2. Unzip + locate the dist (find index.html, use ITS directory) ──────────
# The release zip's top level may be either the dist contents directly or a
# single wrapper dir — locate the SPA entrypoint and use the directory it lives
# in, so either layout installs correctly.
say "unpacking IT-Tools dist"
rm -rf "${WORK}/unz" && mkdir -p "${WORK}/unz"
unzip -q -o "${ZIP_LOCAL}" -d "${WORK}/unz" || die "unzip failed for ${ZIP_LOCAL}"
IDX="$(find "${WORK}/unz" -maxdepth 3 -name index.html -type f 2>/dev/null | head -1)"
[ -n "${IDX}" ] || die "no index.html found inside ${ZIP_LOCAL} — unexpected release layout"
DIST_SRC="$(dirname "${IDX}")"
ok "located IT-Tools dist at $(basename "${DIST_SRC}")/ (index.html present)"

# ── 2.5 Self-host figlet fonts for the ASCII-Art tool (correctness fix) ──────
# The ascii-text-drawer chunk hard-codes figlet's fontPath to the unpkg CDN
# (//unpkg.com/figlet@<ver>/fonts/) and the prebuilt release ships NO .flf font
# files, so EVERY font errors ("Current settings resulted in error") whenever
# that third-party CDN fetch fails (it commonly does behind a hardened edge).
# Fix = ship the figlet fonts into dist/fonts/ and rewrite the CDN path to a
# same-origin /fonts/ path (the vhost below also serves /fonts/). This is
# NON-fatal (cosmetic tool) and grep-guarded so it stays idempotent. The hashed
# chunk filename changes per release, so we glob it. Override via FIGLET_VER.
FIGLET_VER="${FIGLET_VER:-1.6.0}"
FIGLET_SHA256="${FIGLET_SHA256:-0d4da17fef5432b7ffd0ca00980b89dca38e694fadb8d919977e6371f034d7d9}"
if ls "${DIST_SRC}"/assets/ascii-text-drawer-*.js >/dev/null 2>&1 \
   && grep -lq 'unpkg.com/figlet' "${DIST_SRC}"/assets/ascii-text-drawer-*.js 2>/dev/null; then
  say "self-hosting figlet ${FIGLET_VER} fonts (dist bundles none; chunk points at unpkg CDN)"
  FTMP="${WORK}/figlet"
  mkdir -p "${FTMP}"
  # npm registry tarball, verified inline. A curl OR a checksum failure falls
  # through to the WARN branch (NON-fatal) — but we never extract an unverified
  # tarball.
  if curl -fsSL --retry 3 -m 180 -o "${FTMP}/figlet.tgz" \
        "https://registry.npmjs.org/figlet/-/figlet-${FIGLET_VER}.tgz" \
     && echo "${FIGLET_SHA256}  ${FTMP}/figlet.tgz" | sha256sum -c - >/dev/null 2>&1; then
    tar xzf "${FTMP}/figlet.tgz" -C "${FTMP}" 2>/dev/null || true
    if ls "${FTMP}"/package/fonts/*.flf >/dev/null 2>&1; then
      mkdir -p "${DIST_SRC}/fonts"
      cp -f "${FTMP}"/package/fonts/*.flf "${DIST_SRC}/fonts/"
      # repoint figlet from the unpkg CDN to our same-origin /fonts/ path
      sed -i 's#//unpkg.com/figlet@'"${FIGLET_VER}"'/fonts/#/fonts/#g' \
        "${DIST_SRC}"/assets/ascii-text-drawer-*.js
      NF="$(ls "${DIST_SRC}"/fonts/*.flf 2>/dev/null | wc -l | tr -d ' ')"
      if grep -lq 'unpkg.com/figlet' "${DIST_SRC}"/assets/ascii-text-drawer-*.js 2>/dev/null; then
        warn "sed did not fully repoint the chunk — check the unpkg URL form"
      else
        ok "figlet fonts self-hosted (${NF} .flf in dist/fonts/) + chunk repointed to /fonts/"
      fi
    else
      warn "figlet tarball had no package/fonts/*.flf — ASCII Art tool may still error"
    fi
  else
    warn "could not fetch/verify figlet fonts from npm (download error or sha256 mismatch) — ASCII Art tool stays CDN-dependent"
  fi
else
  say "figlet fonts already self-hosted (chunk not pointing at unpkg) — skipping"
fi

# ── 3. Install the dist into the userland serve root ─────────────────────────
# Caddy runs inside proot-Debian and cannot see the host/SD filesystem, so the
# bytes it serves MUST live on the userland rootfs. We tar the prepared dist over
# stdin and extract it inside the userland so we never hardcode the rootfs path.
# Clean the target first for a deterministic layout; world-readable so Caddy
# (any uid in the userland) can serve it.
say "installing IT-Tools dist into the userland (${SERVE_ROOT})"
in_debian "rm -rf ${SERVE_ROOT} && mkdir -p ${SERVE_ROOT}"
( cd "${DIST_SRC}" && tar -cf - . ) \
  | proot-distro login debian -- bash -lc "tar -xf - -C ${SERVE_ROOT}" \
  || die "failed to install the IT-Tools dist into the userland"
in_debian "chmod -R a+rX ${SERVE_ROOT}" >/dev/null 2>&1 || true
in_debian "[ -s ${SERVE_ROOT}/index.html ]" \
  || die "IT-Tools install looks incomplete (${SERVE_ROOT}/index.html missing)"
ok "IT-Tools dist installed at ${SERVE_ROOT} (index.html present)"

# ── 4. Write the self-contained vhost into /etc/caddy/apps/ ──────────────────
# One file per optional app; the core Caddyfile imports /etc/caddy/apps/*.caddy.
# Listener style matches the chat.${DOMAIN} block: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS), security headers,
# then a static file_server rooted at the dist. The forward_auth block is
# COMMENTED OUT: the DEFAULT auth is a
# Cloudflare Access policy at the edge; uncomment it only if you run the optional
# Matrix-SSO gateway add-on (see docs/APP_AUTH.md).
say "writing the IT-Tools vhost to /etc/caddy/apps/ittools.caddy (host: tools.${DOMAIN})"
in_debian 'mkdir -p /etc/caddy/apps'
proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/ittools.caddy' <<EOF
# ============================================================================
# IT-Tools (developer toolbox) — tools.${DOMAIN}   (static, no backend)
# A Vue/Vite SPA where every tool runs client-side: no API, no database, no
# process. Caddy serves the static bytes from ${SERVE_ROOT} (in-userland).
# Installed by scripts/apps/ittools.sh.
#
# AUTH: IT-Tools has NO auth of its own. By default protect this host with a
# Cloudflare Access policy at the edge (Cloudflare dashboard). To gate it with
# the OPTIONAL Matrix-SSO gateway instead, uncomment the forward_auth block
# below (the /authgw/* reverse_proxy must precede it). See docs/APP_AUTH.md.
# ============================================================================
http://tools.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		Cross-Origin-Opener-Policy same-origin
		Cross-Origin-Resource-Policy same-origin
		-Server
	}

	# ── OPTIONAL: Matrix-SSO gateway add-on (default is Cloudflare Access) ──
	# Uncomment to require a Matrix-SSO session cookie for the whole site. The
	# three parts MUST precede the file_server below: the /authgw/* handler keeps
	# the login form reachable (else the 302-to-login loops), the request_header
	# strips any client-forged Remote-User before the gate, and forward_auth then
	# gates everything else. See docs/APP_AUTH.md.
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

	# Static SPA — every tool is pure client-side JS, so the whole site is a
	# plain file_server.
	root * ${SERVE_ROOT}
	file_server
}
EOF

# ── 5. Validate inside the userland (fail closed) ────────────────────────────
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place"

# ── Done ─────────────────────────────────────────────────────────────────────
ok "IT-Tools installed (${ITTOOLS_TAG}). Static dist at ${SERVE_ROOT} (in userland); no process to supervise — Caddy serves it."
say "If the stack is already running, reload Caddy to pick up the new vhost:"
say "    scripts/start-stack.sh --restart"
warn "IT-Tools has NO auth of its own — protect tools.${DOMAIN} with a Cloudflare Access policy"
warn "    (Cloudflare Zero Trust dashboard), or enable the optional gateway block in the vhost (see docs/APP_AUTH.md)."
say  "MANUAL Cloudflare step: add a public hostname  tools.${DOMAIN}  →  http://localhost:${CADDY_PORT}"
say  "    in the Cloudflare Tunnel config (Zero Trust → Tunnels → your tunnel → Public Hostnames → Add)."
say  "    (plain HTTP — the tunnel terminates public TLS at the Cloudflare edge.)"
