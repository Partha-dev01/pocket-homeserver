#!/usr/bin/env bash
#
# apps/radicale.sh — install + supervise Radicale (a lightweight CalDAV / CardDAV
# / tasks server) as an OPTIONAL app behind the loopback Caddy edge, on
# dav.${DOMAIN}.
#
# Radicale is pure Python (no arm64 binary). We install it into a dedicated venv
# on ext4 inside the Debian userland and run it on loopback 127.0.0.1:5232, fronted
# by Caddy at the vhost ROOT so Radicale's built-in /.well-known/caldav|carddav
# 302s drive client discovery (DAVx5 / Thunderbird / iOS / Apple Calendar).
#
# What it does (idempotent — review before running):
#   1. installs python3-venv into the userland, creates a venv on ext4, and pip-
#      installs the pinned Radicale + bcrypt. bcrypt is forced to a PREBUILT
#      aarch64 wheel (--only-binary) so it can NEVER trigger a Rust compile on the
#      phone — if no wheel resolves it fails CLOSED (see the argon2 fallback note),
#   2. keeps the collection root + config + htpasswd on ext4
#      ($HOME/.pocket/radicale, bind-mounted to /opt/radicale/var) — NEVER on the
#      exFAT SD card (its multifilesystem backend needs rename-over-existing, fcntl
#      locks, mtime sync-tokens, and chmod-based privacy — all of which exFAT lacks),
#   3. writes a hardened config (hosts = 127.0.0.1:5232, htpasswd+bcrypt auth,
#      owner_only rights) and ASSERTS the loopback bind fail-closed,
#   4. seeds an initial user from ${ADMIN_USER}/${ADMIN_PASSWORD} (bcrypt hash, the
#      plaintext fed OFF-ARGV via the environment) into a 0600 htpasswd,
#   5. writes a self-contained Caddy vhost (root-mounted, flush_interval -1 for
#      streaming REPORTs) + validates the full Caddyfile fail-closed,
#   6. supervises the venv's radicale on loopback via the shared lib.
#
# AUTH MODEL — sharp edge: CalDAV/CardDAV clients send HTTP Basic and CANNOT
# follow a 302-to-login. So dav.${DOMAIN} must NOT sit behind the interactive
# forward_auth / Matrix-SSO / CF-Access redirect — Radicale's OWN bcrypt htpasswd
# is the auth, plus an operator-side Cloudflare Access SERVICE-TOKEN exemption for
# dav.${DOMAIN} (this script wires nothing for it). The admin panel can render a
# QR "connect device" card for onboarding (see docs/DAV.md). See docs/APP_AUTH.md.
#
# Generalized from the app patterns in this repo; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your public domain, e.g. example.com"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial Radicale (CalDAV/CardDAV) password (set in .env)"
require_cmd proot-distro

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_RADICALE=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Radicale is a pure-Python wheel on PyPI (per-file sha256 published there); its
# deps are pure-Python except bcrypt, which installs from an official prebuilt
# aarch64 wheel. We pin Radicale exactly (the libpass-vs-passlib default can shift
# between minors). To upgrade: bump RADICALE_VERSION, re-run; then re-run
# `radicale --verify-storage`. bcrypt is left unpinned so pip picks the current
# prebuilt wheel for the userland's Python/libc.
RADICALE_VERSION="${RADICALE_VERSION:-3.7.5}"
RADICALE_PORT="${RADICALE_PORT:-5232}"
RAD_HOST="dav.${DOMAIN}"
RAD_USER="${ADMIN_USER:-admin}"

INSTALL_DIR=/opt/radicale                         # in userland — the venv lives here (ext4)
VENV="${INSTALL_DIR}/venv"
RAD_BIN="${VENV}/bin/radicale"

# Collection root + config + htpasswd on ext4 (NOT exFAT), on the HOST under
# $HOME/.pocket so they survive a rootfs rebuild and live on a real filesystem
# (rename-over-existing, fcntl locks, mtime, unix perms). Bind-mounted to
# /opt/radicale/var. ── This placement is correctness + privacy load-bearing. ──
VAR_BACKING="${HOME}/.pocket/radicale"            # on ext4 (host)
VAR_MOUNT="${INSTALL_DIR}/var"                     # in userland — bind target
COLLECTIONS="${VAR_MOUNT}/collections"             # collection root (inside the bind)
CONFIG="${VAR_MOUNT}/config"                        # radicale config (inside the bind)
HTPASSWD="${VAR_MOUNT}/users.htpasswd"              # bcrypt htpasswd (inside the bind)
HTPASSWD_HOST="${VAR_BACKING}/users.htpasswd"       # same file as seen on the host

# ── Collection dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ─────────────
assert_ext4 "${VAR_BACKING}" "Radicale collection root"
mkdir -p "${VAR_BACKING}" || die "cannot create ${VAR_BACKING} on ext4"
chmod 700 "${VAR_BACKING}" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. python3-venv + pip in the userland (idempotent) ───────────────────────
run_once radicale-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends python3 python3-venv python3-pip ca-certificates
' || die "could not install python3-venv inside the userland"

# ── 2. venv on ext4 + pinned Radicale + PREBUILT bcrypt (fail-closed) ────────
# Idempotent: skip if the venv already has the pinned Radicale. bcrypt is installed
# with --only-binary=:all: so a missing aarch64 wheel FAILS CLOSED rather than
# silently compiling Rust on the phone (the documented argon2-cffi fallback is a
# manual choice, not an automatic pivot — see docs/DAV.md).
if in_debian "[ -x '${RAD_BIN}' ] && '${RAD_BIN}' --version 2>/dev/null | grep -q '${RADICALE_VERSION}'"; then
  ok "Radicale ${RADICALE_VERSION} already installed in the venv"
else
  say "creating the venv + installing Radicale ${RADICALE_VERSION} + bcrypt (prebuilt wheel only)"
  in_debian "
    set -e
    mkdir -p '${INSTALL_DIR}'
    [ -x '${VENV}/bin/python' ] || python3 -m venv '${VENV}'
    '${VENV}/bin/pip' install --quiet --upgrade pip
    # bcrypt: PREBUILT WHEEL ONLY — fail closed if no aarch64 wheel resolves.
    '${VENV}/bin/pip' install --quiet --only-binary=:all: 'bcrypt' \
      || { echo 'FATAL: no prebuilt bcrypt aarch64 wheel resolved — refusing to compile Rust on the phone. See docs/DAV.md (argon2 fallback).'; exit 3; }
    '${VENV}/bin/pip' install --quiet 'radicale==${RADICALE_VERSION}'
  " 2>&1 | grep -v 'proot warning' || die "Radicale venv install failed (bcrypt wheel missing, or pip error — see above)"
  in_debian "[ -x '${RAD_BIN}' ]" || die "radicale missing in the venv after install at ${RAD_BIN}"
  ok "Radicale ${RADICALE_VERSION} + bcrypt installed in ${VENV}"
fi

# ── 3. Collection root, config, bind target ──────────────────────────────────
in_debian "mkdir -p '${VAR_MOUNT}'" || die "failed to create ${VAR_MOUNT} mountpoint in the userland"
proot-distro login debian --bind "${VAR_BACKING}:${VAR_MOUNT}" -- bash -lc "mkdir -p '${COLLECTIONS}'" \
  || die "failed to create the collection root ${COLLECTIONS}"

# ── 4. Seed the initial user (bcrypt) — OFF-ARGV ─────────────────────────────
# Only on a FRESH htpasswd (so a re-run never resets a password you changed). The
# plaintext reaches Python ONLY via the environment (RAD_SEED_PASSWORD), never on
# argv; Python (the venv's bcrypt) writes "user:$2b$..." to a 0600 htpasswd.
if [ -f "${HTPASSWD_HOST}" ]; then
  ok "Radicale htpasswd already present at ${HTPASSWD_HOST} — NOT re-seeding (idempotent)"
else
  say "seeding the initial Radicale user '${RAD_USER}' (bcrypt, off-argv via env)"
  proot-distro login debian \
    --bind "${VAR_BACKING}:${VAR_MOUNT}" \
    -- env RAD_SEED_PASSWORD="${ADMIN_PASSWORD}" RAD_SEED_USER="${RAD_USER}" \
       bash -lc "umask 077; '${VENV}/bin/python' - '${HTPASSWD}' <<'PY'
import os, sys
pw = os.environ['RAD_SEED_PASSWORD'].encode()   # plaintext from env, NEVER argv
user = os.environ['RAD_SEED_USER']
out = sys.argv[1]
import bcrypt
h = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('%s:%s\n' % (user, h))
print('htpasswd seeded for user', user)
PY" 2>&1 | grep -v 'proot warning' || die "Radicale htpasswd seed failed"
  in_debian "chmod 600 '${HTPASSWD}'" 2>/dev/null || true
  ok "seeded Radicale user '${RAD_USER}' (password from .env ADMIN_PASSWORD)"
fi

# ── 5. Hardened config (loopback, bcrypt htpasswd, owner_only) ───────────────
# Written into the bind-mounted ext4 var dir. hosts is forced to loopback; step 6
# greps it to assert. owner_only = each user only sees their own collections.
say "writing the Radicale config → ${CONFIG}"
proot-distro login debian --bind "${VAR_BACKING}:${VAR_MOUNT}" -- bash -lc "umask 077; cat > '${CONFIG}'" <<EOF
# Generated by apps/radicale.sh — hardened, loopback-only CalDAV/CardDAV server.

[server]
# ┌── SECURITY-LOAD-BEARING: loopback bind ────────────────────────────────────
# │ Bind ONLY to 127.0.0.1 so the sole path in is Caddy + the Cloudflare Tunnel.
# │ Do NOT use 0.0.0.0 or [::]. Step 6 asserts this line.
# └────────────────────────────────────────────────────────────────────────────
hosts = 127.0.0.1:${RADICALE_PORT}
max_connections = 8

[auth]
type = htpasswd
htpasswd_filename = ${HTPASSWD}
htpasswd_encryption = bcrypt
# Slow down brute force a touch.
delay = 1

[storage]
filesystem_folder = ${COLLECTIONS}

[rights]
# Each user may only read/write their OWN collections.
type = owner_only

[logging]
mask_passwords = True
EOF
in_debian "chmod 600 '${CONFIG}'" 2>/dev/null || true
ok "wrote ${CONFIG} (chmod 600)"

# ── 6. FAIL-CLOSED loopback assert ───────────────────────────────────────────
say "asserting the Radicale bind is loopback"
in_debian "grep -Eq '^[[:space:]]*hosts[[:space:]]*=[[:space:]]*127\.0\.0\.1:${RADICALE_PORT}[[:space:]]*\$' '${CONFIG}'" \
  || die "Radicale hosts is NOT 127.0.0.1:${RADICALE_PORT} — refusing to start a LAN-exposed DAV server (check ${CONFIG})"
in_debian "grep -Eq '^[[:space:]]*hosts[[:space:]]*=[[:space:]]*(0\.0\.0\.0|\[::\])' '${CONFIG}'" \
  && die "Radicale still binds a public address — refusing to start (check ${CONFIG})" || true
ok "Radicale bind confirmed loopback (127.0.0.1:${RADICALE_PORT})"

# In-userland launcher (keeps the supervise→proot quoting simple).
proot-distro login debian -- bash -lc "umask 077; cat > '${INSTALL_DIR}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/radicale.sh.
exec '${RAD_BIN}' --config '${CONFIG}'
LAUNCH
in_debian "chmod +x '${INSTALL_DIR}/run.sh'" || die "failed to make ${INSTALL_DIR}/run.sh executable"

# ── 7. Caddy vhost (ROOT-mounted so .well-known discovery works) ─────────────
# Mount Radicale at the vhost root: it serves /.well-known/caldav and
# /.well-known/carddav itself (302 → /USER/caldav/ etc.), which is what DAVx5/
# Thunderbird/iOS expect. flush_interval -1 streams the chunked REPORT bodies.
# NO forward_auth here — CalDAV/CardDAV clients send Basic auth and can't do a 302.
say "writing the Radicale vhost → /etc/caddy/apps/radicale.caddy"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/radicale.caddy' <<EOF
# dav.${DOMAIN} — Radicale (CalDAV / CardDAV / tasks).
# Written by scripts/apps/radicale.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here. Auth = Radicale's OWN bcrypt htpasswd (Basic).
# DO NOT put this behind the interactive forward_auth / CF Access redirect — DAV
# clients send Basic auth and cannot follow a 302 login. Use a CF Access
# SERVICE-TOKEN exemption for this hostname instead. See docs/DAV.md.
http://dav.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		-Server
	}

	# Root-mount → Radicale answers /.well-known/caldav|carddav itself for client
	# auto-discovery. flush_interval -1 streams chunked CalDAV REPORT responses.
	reverse_proxy 127.0.0.1:${RADICALE_PORT} {
		flush_interval -1
		header_up Host {host}
		header_up X-Forwarded-Proto https
	}
}
EOF
then
  die "failed to write /etc/caddy/apps/radicale.caddy into the userland"
fi

say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/radicale.caddy"
ok "Radicale vhost written + Caddyfile validates"

# ── 8. Supervise radicale on loopback ────────────────────────────────────────
say "supervising Radicale (venv, bind 127.0.0.1:${RADICALE_PORT}; collections on ${VAR_BACKING})"
supervise radicale -- \
  proot-distro login debian \
  --bind "${VAR_BACKING}:${VAR_MOUNT}" \
  -- bash "${INSTALL_DIR}/run.sh"

# ── 9. Best-effort health check ──────────────────────────────────────────────
# Radicale requires auth, so an unauthenticated GET returns 401 — which still
# proves it is up. Treat any HTTP response as healthy.
say "waiting for Radicale to answer on 127.0.0.1:${RADICALE_PORT}"
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null -m 3 "http://127.0.0.1:${RADICALE_PORT}/" 2>/dev/null \
     || curl -s -o /dev/null -m 3 "http://127.0.0.1:${RADICALE_PORT}/" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Radicale answering on 127.0.0.1:${RADICALE_PORT} (401 without credentials is expected)"
else
  warn "Radicale not yet answering on :${RADICALE_PORT} — check ${POCKET_LOG_DIR}/radicale.log (the supervisor keeps retrying)"
fi

# ── 10. Closing notes ─────────────────────────────────────────────────────────
cat >&2 <<EOF

$(ok "Radicale installed + supervised on 127.0.0.1:${RADICALE_PORT} (collections on ${VAR_BACKING})" 2>&1)

  Initial user: '${RAD_USER}' (password from .env ADMIN_PASSWORD). Add more users
  with bcrypt entries in ${HTPASSWD_HOST} (htpasswd -B, or the admin panel's
  Radicale connect-card flow).

  CLIENTS (DAVx5 / Thunderbird / iOS / Apple):
    Base URL: https://${RAD_HOST}/${RAD_USER}/   (auto-discovery via
    https://${RAD_HOST}/.well-known/caldav | /.well-known/carddav). The admin
    panel can show a scannable "connect device" QR card. See docs/DAV.md.

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${RAD_HOST}  ->  http://localhost:${CADDY_PORT}   (plain HTTP).
    2. Cloudflare Access: DAV clients send Basic auth and CANNOT complete an
       interactive login redirect — add a SERVICE-TOKEN (Service Auth) exemption
       for ${RAD_HOST}, do NOT put it behind a normal Access login policy.
       Radicale's bcrypt htpasswd is the real gate. See docs/DAV.md + docs/APP_AUTH.md.

  Backups: tar the ext4 collection dir; copy the tarball to the SD card — never
  sync the live tree onto exFAT. After any upgrade run \`radicale --verify-storage\`.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
EOF

ok "apps/radicale.sh done (dav.${DOMAIN} once the Cloudflare hostname + service-token exemption are added)"

# Generalized from a working deployment; review before running.
