#!/usr/bin/env bash
#
# apps/gatus.sh — install + supervise Gatus (TwiN/gatus), a self-hosted uptime /
# health dashboard, as an OPTIONAL app behind the loopback Caddy edge.
#
# Gatus ships NO arm64 release binary, so it is BUILT FROM SOURCE on-device: a
# pinned Go toolchain is dropped into the Debian userland, the pinned Gatus tag is
# cloned, and a fully-static `CGO_ENABLED=0 GOARCH=arm64 go build` produces the
# binary. We then run that binary INSIDE the userland (proot) for consistency with
# the rest of pocket-homeserver, fronted by the core Caddy on ${CADDY_BIND}:${CADDY_PORT};
# the public hostname is status.${DOMAIN}.
#
# ⚠ FIRST RUN IS SLOW: downloading the Go toolchain and compiling Gatus on a phone
# takes several minutes (sometimes 10+). Re-runs skip the build (idempotent).
#
# What it does (idempotent — safe to re-run):
#   1. installs the pinned Go toolchain into the userland (fetch_verified the
#      official go.dev tarball, sha256-pinned fail-closed, into ${DATA_DIR}/binaries),
#   2. clones the pinned Gatus tag into the userland and builds the static arm64
#      binary (skipped if a binary for this version already exists),
#   3. writes a MINIMAL, generic config.yaml into the userland (memory storage,
#      loopback bind, a couple of clearly-commented EXAMPLE endpoints to copy),
#   4. writes a self-contained Caddy vhost to /etc/caddy/apps/gatus.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   5. supervises the binary via the shared lib (respawn + identity-checked pid),
#      running it inside the userland.
#
# ⚠ STORAGE = memory (NOT sqlite). Gatus's SQLite backend uses mattn/go-sqlite3,
# which requires cgo and conflicts with the mandated CGO_ENABLED=0 static build.
# So config.yaml uses `storage.type: memory`: monitoring history does NOT survive
# a Gatus restart (results live in RAM and repopulate within one probe interval).
# Fine for a single-operator status view; for persistence you would need a cgo
# build (+ a C toolchain in proot) or PostgreSQL — both out of scope here.
#
# AUTH MODEL (default): the status page has NO app-level login. The public
# hostname status.${DOMAIN} is gated at the Cloudflare edge with Cloudflare Access
# (a policy you add in the Cloudflare dashboard — NOT configured by this script).
# An optional Matrix-SSO gateway add-on (single sign-on across apps) is documented
# in docs/APP_AUTH.md; its hooks are present here only as a COMMENTED-OUT block in
# the Caddy vhost.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_GATUS=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned versions ──────────────────────────────────────────────────────────
# Gatus has no arm64 release binary, so we build from a PINNED tag with a PINNED
# Go toolchain (sha256 fail-closed on the Go tarball). All values are
# env-overridable. Versions + the Go sha256 are copied verbatim from the reference
# deployment's installer. To upgrade: bump GATUS_VER (must satisfy go.mod's `go`
# directive); if the toolchain must move too, bump GO_VER **and** GO_SHA256
# together (get the new hash from https://go.dev/dl/ — it lists the official
# sha256 for each tarball).
GATUS_VER="${GATUS_VER:-5.36.0}"                       # latest stable at reference time; no release binary -> build
GO_VER="${GO_VER:-1.26.3}"                             # go.mod minimum at the pinned Gatus tag
GO_SHA256="${GO_SHA256:-9d89a3ea57d141c2b22d70083f2c8459ba3890f2d9e818e7e933b75614936565}"  # official go.dev checksum for go${GO_VER}.linux-arm64.tar.gz

GATUS_REPO="${GATUS_REPO:-https://github.com/TwiN/gatus.git}"
GO_TARBALL="go${GO_VER}.linux-arm64.tar.gz"
GO_URL="${GO_URL:-https://go.dev/dl/${GO_TARBALL}}"

# ── Service-local config ─────────────────────────────────────────────────────
GATUS_PORT="${GATUS_PORT:-9115}"           # loopback bind; Caddy fronts the public edge
GATUS_HOST="status.${DOMAIN}"              # public hostname
SRC_DIR="/opt/gatus-src"                   # in-userland build tree
GO_ROOT="/opt/go"                          # in-userland pinned Go toolchain
BIN_USERLAND="${SRC_DIR}/gatus"            # built static binary (inside the userland)
CONF_USERLAND="/opt/gatus/config.yaml"     # config the binary reads at runtime
CACHE_DIR="${DATA_DIR}/binaries"
GO_LOCAL="${CACHE_DIR}/${GO_TARBALL}"

mkdir -p "${CACHE_DIR}"

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Pinned Go toolchain inside the userland ───────────────────────────────
# go.mod needs >= ${GO_VER}; Debian's apt `golang` lags, so we drop the official
# static tarball into the userland at ${GO_ROOT}. fetch_verified (common.sh)
# reuses a cached copy that already matches the pin and deletes + aborts on any
# mismatch. Idempotent: skip if the toolchain already reports the pinned version.
if in_debian "[ -x ${GO_ROOT}/bin/go ] && ${GO_ROOT}/bin/go version 2>/dev/null | grep -q 'go${GO_VER}'"; then
  ok "Go ${GO_VER} already present in the userland at ${GO_ROOT}"
else
  say "fetching + verifying the pinned Go ${GO_VER} toolchain"
  fetch_verified "${GO_URL}" "${GO_LOCAL}" "${GO_SHA256}"
  # Ensure git + ca-certificates are present in the userland (needed for the clone
  # and TLS verification of the source fetch).
  in_debian "command -v git >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends git ca-certificates; }" \
    || die "could not ensure git/ca-certificates inside the userland"
  say "extracting Go ${GO_VER} into the userland (${GO_ROOT})"
  # Stream the verified tarball in over stdin so we never hardcode the rootfs path;
  # extract into /opt (the tarball unpacks to a top-level `go/` dir => ${GO_ROOT}).
  proot-distro login debian -- bash -lc "
    set -e
    rm -rf ${GO_ROOT}
    tmp=\$(mktemp /tmp/go.XXXXXX.tar.gz)
    cat > \"\$tmp\"
    mkdir -p /opt
    tar -C /opt -xzf \"\$tmp\"
    rm -f \"\$tmp\"
  " < "${GO_LOCAL}" || die "failed extracting the Go toolchain into the userland"
  in_debian "${GO_ROOT}/bin/go version 2>/dev/null | grep -q 'go${GO_VER}'" \
    || die "Go ${GO_VER} not runnable after extract (wrong arch tarball?)"
  ok "Go ${GO_VER} installed in the userland"
fi

# ── 2. Clone the pinned Gatus tag + build the static arm64 binary ────────────
# Idempotent: skip the clone if the tag is already checked out, and skip the build
# if a binary reporting this version already exists.
if in_debian "[ -f ${SRC_DIR}/go.mod ] && git -C ${SRC_DIR} describe --tags 2>/dev/null | grep -qx 'v${GATUS_VER}'"; then
  say "Gatus source v${GATUS_VER} already checked out at ${SRC_DIR}"
else
  say "cloning Gatus v${GATUS_VER} source -> ${SRC_DIR}"
  in_debian "set -e; rm -rf ${SRC_DIR}; git clone --depth 1 --branch v${GATUS_VER} ${GATUS_REPO} ${SRC_DIR}" \
    || die "git clone of Gatus v${GATUS_VER} failed"
fi

NEED_BUILD=1
if in_debian "[ -x ${BIN_USERLAND} ] && ${BIN_USERLAND} --version 2>/dev/null | grep -q '${GATUS_VER}'"; then
  NEED_BUILD=0
fi
if [ "${NEED_BUILD}" = 1 ]; then
  say "building Gatus v${GATUS_VER} (CGO_ENABLED=0 GOARCH=arm64; this can take SEVERAL MINUTES on a phone)"
  # Static build: CGO off => no libc/sqlite dependency (hence memory storage).
  # -trimpath + -ldflags '-s -w' shrink the binary. GOFLAGS=-mod=mod lets the
  # build resolve modules against the network on first run.
  in_debian "set -e
    cd ${SRC_DIR}
    export PATH=${GO_ROOT}/bin:\$PATH
    export GOFLAGS=-mod=mod
    export GOCACHE=/tmp/go-build-cache GOPATH=/root/go
    export CGO_ENABLED=0 GOOS=linux GOARCH=arm64
    ${GO_ROOT}/bin/go build -trimpath -ldflags '-s -w' -o ${BIN_USERLAND} ." \
    || die "gatus go build failed (see output above)"
  in_debian "[ -x ${BIN_USERLAND} ]" || die "gatus binary missing after build"
  ver="$(in_debian "${BIN_USERLAND} --version 2>&1 | head -1" || true)"
  [ -n "${ver}" ] || die "the freshly built gatus binary did not run inside the userland"
  ok "gatus built: ${ver} (static, CGO off)"
else
  say "gatus v${GATUS_VER} binary already built (skip build)"
fi

# ── 3. Minimal, generic config.yaml (written into the userland) ──────────────
# Deliberately MINIMAL and generic: a UI title derived from ${DOMAIN}, memory
# storage (the static CGO-off build cannot use sqlite), a loopback web bind so
# only Caddy fronts it, and a SMALL set of clearly-commented EXAMPLE endpoints.
#
# There is intentionally NO `security:` / OIDC block — the default front door is
# Cloudflare Access at the edge (see the vhost + the closing notes).
#
# Probe strategy: public web surfaces are probed via the shared loopback Caddy
# listener (http://127.0.0.1:${CADDY_PORT}/...) with a `Host:` header so the right
# vhost answers and all traffic stays on-box (no outbound HTTPS). Copy the
# commented templates below to add your own apps.
say "writing minimal generic config -> ${CONF_USERLAND}"
in_debian "mkdir -p $(dirname "${CONF_USERLAND}")"
proot-distro login debian -- bash -lc "umask 077; cat > ${CONF_USERLAND}" <<EOF
# Generated by apps/gatus.sh — minimal, generic uptime monitor for pocket-homeserver.
# Storage = memory (the static CGO-off build cannot use sqlite, so history does NOT
# survive a restart). Web bind is loopback only; the core Caddy fronts the edge.
# No security/OIDC block: the status page is gated at the Cloudflare edge with
# Cloudflare Access. Re-run apps/gatus.sh to regenerate this file.

web:
  address: "127.0.0.1"
  port: ${GATUS_PORT}

ui:
  title: "${DOMAIN} status"
  header: "${DOMAIN} status"
  description: "Service health for ${DOMAIN}"

storage:
  type: memory
  maximum-number-of-results: 100
  maximum-number-of-events: 50

# Monitored endpoints. The default front door is the local Caddy on the shared
# loopback listener (127.0.0.1:${CADDY_PORT}); probing through it with a Host:
# header keeps everything on-box and exercises the same path real visitors hit.
endpoints:
  # EXAMPLE — the Matrix homeserver via the local Caddy edge. The client/versions
  # endpoint is unauthenticated and returns 200 when the homeserver is healthy.
  - name: matrix
    group: core
    url: "http://127.0.0.1:${CADDY_PORT}/_matrix/client/versions"
    interval: 60s
    client:
      timeout: 10s
    conditions:
      - "[STATUS] == 200"
    headers:
      Host: "chat.${DOMAIN}"

  # EXAMPLE — Gatus's own health endpoint (proves the monitor itself is up).
  - name: gatus-self
    group: internal
    url: "http://127.0.0.1:${GATUS_PORT}/health"
    interval: 60s
    client:
      timeout: 5s
    conditions:
      - "[STATUS] == 200"

  # ── TEMPLATES — copy one of these per app you enable, then uncomment ────────
  # Apps gated at the Cloudflare edge are still reachable on the LOOPBACK Caddy
  # without that gate, so probe them here via 127.0.0.1:${CADDY_PORT} + a Host
  # header. Adjust the path/condition to a real health route for each app.
  #
  # - name: bookmarks
  #   group: apps
  #   url: "http://127.0.0.1:${CADDY_PORT}/health"
  #   interval: 60s
  #   client:
  #     timeout: 10s
  #   conditions:
  #     - "[STATUS] == 200"
  #   headers:
  #     Host: "links.${DOMAIN}"
  #
  # - name: tasks
  #   group: apps
  #   url: "http://127.0.0.1:${CADDY_PORT}/api/v1/info"
  #   interval: 120s
  #   client:
  #     timeout: 10s
  #   conditions:
  #     # An app whose "/" requires login (e.g. behind the optional Matrix-SSO
  #     # gateway) may answer the probe with a 302 redirect — widen the match:
  #     - "[STATUS] == 200 || [STATUS] == 302"
  #   headers:
  #     Host: "tasks.${DOMAIN}"
EOF
in_debian "chmod 600 ${CONF_USERLAND}" || true
ok "wrote ${CONF_USERLAND} (chmod 600; memory storage; ${GATUS_HOST})"

# ── 4. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
# Matches the core Caddyfile listener style EXACTLY: explicit
# http://<host>:${CADDY_PORT} + bind ${CADDY_BIND} (plain HTTP on the shared high
# loopback port; the Cloudflare Tunnel terminates public TLS). The core Caddyfile
# imports /etc/caddy/apps/*.caddy, so dropping this file in is all it takes.
say "writing the Caddy vhost -> /etc/caddy/apps/gatus.caddy"
proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/gatus.caddy' <<EOF
# Gatus (status / uptime monitor) — optional app vhost for pocket-homeserver.
# Public hostname status.${DOMAIN}; bound to loopback (the Cloudflare Tunnel
# forwards public traffic here). By default this hostname is gated at the
# Cloudflare edge with Cloudflare Access (configured in the Cloudflare dashboard).
http://${GATUS_HOST}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (single sign-on across apps). Disabled by
	# default — the default front door is Cloudflare Access at the edge. To enable,
	# run the optional Matrix-auth gateway and uncomment this block (see
	# docs/APP_AUTH.md). It must precede the reverse_proxy so unauthenticated
	# requests are redirected to login before reaching Gatus.
	# forward_auth 127.0.0.1:9095 {
	# 	uri /authgw/verify
	# 	copy_headers Remote-User
	# }

	reverse_proxy 127.0.0.1:${GATUS_PORT}
}
EOF
ok "wrote /etc/caddy/apps/gatus.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT restart
# Caddy here — print the restart hint instead so an already-running stack picks up
# the new vhost on the operator's schedule.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/gatus.caddy)"
ok "Caddyfile still valid with the gatus vhost added"

# ── 5. Supervise the service (run the binary inside the userland) ────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs the static
# Gatus binary INSIDE the userland. GATUS_CONFIG_PATH points it at the config we
# wrote above (memory storage => no durable state to bind-mount in).
supervise gatus -- \
  proot-distro login debian \
  -- env GATUS_CONFIG_PATH="${CONF_USERLAND}" "${BIN_USERLAND}"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "Gatus installed + supervised (loopback 127.0.0.1:${GATUS_PORT}; memory storage)"
say "Liveness: curl -sf http://127.0.0.1:${GATUS_PORT}/health"
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${GATUS_HOST}  ->  http://localhost:${CADDY_PORT}  (plain HTTP — the tunnel does TLS)"
say "  2. Add a Cloudflare Access policy (Zero Trust) protecting ${GATUS_HOST} so only"
say "     your chosen identities can reach the status page (this is the default front door)."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."
echo
warn "First run builds Go + Gatus on the phone — expect several minutes (10+ is normal)."

# Generalized from a working deployment; review before running.
