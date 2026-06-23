#!/usr/bin/env bash
#
# apps/filebrowser.sh — install + supervise File Browser (filebrowser/filebrowser
# "classic" v2, the Go web file manager) as an OPTIONAL app behind the loopback
# Caddy edge, on files.${DOMAIN}.
#
# File Browser v2 is browser-only: multi-user accounts + share links, served from
# a single static Go binary (web assets are embedded). It has NO WebDAV and NO
# native OIDC — for mountable network drives or bulk/large sync point users at the
# Dufs or Syncthing apps instead (see docs/FILES.md). It is the MUTUALLY-EXCLUSIVE
# alternative to Dufs: both claim files.${DOMAIN}, so enable exactly one.
#
# What it does (idempotent — review before running):
#   1. downloads the pinned linux-arm64 release tarball (exact version + sha256 as
#      a fail-closed supply-chain check) into ${DATA_DIR}/binaries and extracts the
#      single `filebrowser` binary into the userland at /opt/filebrowser,
#   2. initialises File Browser's BoltDB **on ext4** ($HOME/.pocket/filebrowser,
#      bind-mounted to /opt/filebrowser-db) — never on the exFAT SD card — and on a
#      FRESH db deterministically seeds the admin from ${ADMIN_USER}/${ADMIN_PASSWORD}
#      (off-argv via a bcrypt hash imported through a 0600 file; see step 4),
#   3. writes a self-contained Caddy vhost to /etc/caddy/apps/filebrowser.caddy and
#      validates the full Caddyfile fail-closed (it does NOT restart Caddy),
#   4. supervises the binary on loopback 127.0.0.1:${FB_PORT}, serving the content
#      tree ${DATA_DIR}/files (the exFAT SD bind) at -r /data.
#
# AUTH MODEL (default): File Browser keeps its OWN native login (auth.method=json)
# and the hostname is ALSO gated at the Cloudflare edge with Cloudflare Access (a
# policy you add in the Cloudflare dashboard — NOT configured by this script).
# Public sign-up is turned OFF (--signup=false) so accounts are created only by an
# admin; we seed one admin from ${ADMIN_USER}/${ADMIN_PASSWORD}. An optional
# Matrix-SSO front door (auth.method=proxy) is documented as a COMMENTED block in
# the vhost — see the security note there and docs/APP_AUTH.md.
#
# STORAGE SPLIT (load-bearing): File Browser's config + per-user accounts + share
# links all live INSIDE its BoltDB. That db is a real database with locks, so it
# MUST sit on ext4 — putting it on the exFAT SD (${DATA_DIR}) would corrupt it
# (exFAT/FUSE has no unix perms, no rename-over-existing, no locking semantics).
# We keep the db on the host at $HOME/.pocket/filebrowser (ext4) and bind-mount it
# into the userland, so it also survives a rootfs rebuild. ONLY the served content
# tree (bulk files) lives on exFAT at ${DATA_DIR}/files.
#
# Cloudflare Tunnel uploads are capped at ~100MB per request: a single-request
# browser upload larger than ~100MB will fail at the edge. That is a Cloudflare
# limit, not a File Browser one — for large/bulk transfers use Syncthing/Dufs.
#
# Generalized from a working deployment; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_PASSWORD "the initial File Browser admin password (set in .env)"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this script when
# ENABLE_FILEBROWSER=true), so this script does not re-check that flag.

# ── MUTUAL-EXCLUSION GUARD ────────────────────────────────────────────────────
# Dufs and File Browser both publish on files.${DOMAIN}; running both would write
# two conflicting vhosts for the same hostname. Refuse fail-closed so the operator
# picks exactly one file app.
if [ "${ENABLE_DUFS:-false}" = "true" ]; then
  die "ENABLE_DUFS and ENABLE_FILEBROWSER both set — they share files.${DOMAIN}; enable exactly one."
fi

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT version + sha256 (env-overridable, with config/versions.env as the
# central manifest) rather than tracking "latest", so the download fails closed on
# any corruption/tampering. The tarball ships a single `filebrowser` binary (web
# assets embedded). To upgrade: bump FILEBROWSER_VER + FILEBROWSER_SHA256 together
# (the hash is in the release's filebrowser_${FILEBROWSER_VER}_checksums.txt for
# linux-arm64-filebrowser.tar.gz) and re-run. The BoltDB persists across upgrades.
FILEBROWSER_VER="${FILEBROWSER_VER:-2.63.15}"
FILEBROWSER_SHA256="${FILEBROWSER_SHA256:-74dd4e2403235987e4dba26b6e34a6f2c56e9fc98e13d9205c079f9e1c8c42f5}"
FILEBROWSER_TARBALL="linux-arm64-filebrowser.tar.gz"
FILEBROWSER_URL="${FILEBROWSER_URL:-https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VER}/${FILEBROWSER_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
FB_PORT=9118                             # loopback bind; only Caddy reaches it
FB_HOST="files.${DOMAIN}"                # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/filebrowser             # in userland — the binary
BIN="${INSTALL_DIR}/filebrowser"         # in userland — /opt/filebrowser/filebrowser

# DB on ext4 (NOT exFAT). The backing dir is on the HOST under $HOME/.pocket so it
# survives a rootfs rebuild and lives on a real filesystem (locks/perms). It is
# bind-mounted into the userland at /opt/filebrowser-db both at init time and at
# supervise time. The db file path is therefore ALWAYS /opt/filebrowser-db/...
# inside the userland.  ── This split is security/data-integrity load-bearing. ──
DB_BACKING="${HOME}/.pocket/filebrowser"     # on ext4 (host) — survives rootfs rebuild
DB_MOUNT=/opt/filebrowser-db                 # in userland — bind-mount target for the db dir
DB_FILE="${DB_MOUNT}/filebrowser.db"         # BoltDB path as seen inside the userland

# Served content tree: bulk files only, on the exFAT SD card. Bind-mounted to /data
# and passed as -r /data (File Browser's root scope).
CONTENT_BACKING="${DATA_DIR}/files"          # on exFAT SD — bulk content only
CONTENT_MOUNT=/data                          # in userland — File Browser's root scope

CACHE_DIR="${DATA_DIR}/binaries"
FILEBROWSER_LOCAL="${CACHE_DIR}/${FILEBROWSER_TARBALL}"
mkdir -p "${CACHE_DIR}"

# ── DB backing dir on ext4 (host) — created with tight perms BEFORE anything else.
# 700 because it holds the BoltDB (config + accounts + share secrets). We never let
# this path point at ${DATA_DIR} (exFAT). Load-bearing: see the header note.
say "creating the File Browser db dir on ext4 (${DB_BACKING})"
assert_ext4 "${DB_BACKING}" "File Browser BoltDB dir"
mkdir -p "${DB_BACKING}" || die "cannot create the db dir ${DB_BACKING} on ext4"
chmod 700 "${DB_BACKING}" 2>/dev/null || true

# Served content tree on the exFAT SD (bulk only).
say "creating the served content tree on the SD card (${CONTENT_BACKING})"
mkdir -p "${CONTENT_BACKING}" || die "cannot create the content dir ${CONTENT_BACKING} on the SD card"

# ── 1. Download the release tarball, sha256-verified fail-closed ─────────────
# fetch_verified (from common.sh) reuses a cached copy that already matches the
# pin, and deletes + aborts on any mismatch.
fetch_verified "${FILEBROWSER_URL}" "${FILEBROWSER_LOCAL}" "${FILEBROWSER_SHA256}"
ok "File Browser v${FILEBROWSER_VER} tarball ready at ${FILEBROWSER_LOCAL} ($(wc -c < "${FILEBROWSER_LOCAL}") bytes)"

# ── 2. Extract the binary into the userland + verify it runs ─────────────────
# proot-distro manages the rootfs path, so go through `proot-distro login` and
# stream the tarball in over stdin (no hardcoded rootfs location). The tarball
# contains a single `filebrowser` binary at its top level.
say "extracting File Browser into the userland (${BIN})"
in_debian "mkdir -p ${INSTALL_DIR} ${DB_MOUNT}"
proot-distro login debian -- bash -lc "tar -xzf - -C ${INSTALL_DIR} filebrowser && chmod +x ${BIN}" \
  < "${FILEBROWSER_LOCAL}" || die "failed to extract the File Browser binary into the userland"
in_debian "[ -x ${BIN} ]" || die "File Browser binary missing after extract at ${BIN}"
ver="$(in_debian "${BIN} version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "File Browser: ${ver}" || die "File Browser binary did not run inside the userland"

# ── 3. Initialise the BoltDB + apply non-secret config (idempotent) ──────────
# The BoltDB is bind-mounted from ext4. `config init` bootstraps a fresh db; we
# only run it if the db file is absent (re-running it on an existing db would reset
# config). `config set` is idempotent (only the named keys change), so it is safe
# to re-apply on every run to keep config drift-free:
#   --auth.method=json        → File Browser's own login (the default front door)
#   --signup=false            → NO public self-registration (admin creates accounts)
#   --branding.disableExternal→ hide outbound GitHub/docs links in the UI
# Flag names verified against File Browser v2 `config set` docs (filebrowser.org/cli).
# Check the db on the HOST path (it lives on ext4 at ${DB_BACKING}); the in-userland
# ${DB_FILE} is only visible once the --bind mount below is active, so probing it
# via a plain `in_debian` (no bind) would always read empty and wrongly re-seed.
db_existed=0
if [ -f "${DB_BACKING}/filebrowser.db" ]; then
  db_existed=1
fi

proot-distro login debian \
  --bind "${DB_BACKING}:${DB_MOUNT}" \
  -- bash -lc "
    set -e
    if [ ! -f '${DB_FILE}' ]; then
      '${BIN}' -d '${DB_FILE}' config init
    fi
    '${BIN}' -d '${DB_FILE}' config set \
      --auth.method=json \
      --signup=false \
      --branding.disableExternal
  " 2>&1 | grep -v 'proot warning' || die "File Browser config init/set failed inside the userland"
ok "File Browser config applied (auth.method=json, signup off, external links off)"

# ── 4. Deterministic admin seed — SECURITY-LOAD-BEARING ──────────────────────
# A fresh File Browser db otherwise prints a ONE-TIME random admin password to the
# log and forgets it (the "first-user lockout" class). We instead seed a known
# admin from ${ADMIN_USER}/${ADMIN_PASSWORD}, but ONLY on a fresh db (db_existed=0)
# so a re-run never resets an account you may have changed.
#
# OFF-ARGV: classic File Browser v2 has NO stdin/env password input on `users add`
# or `hash` — the password is a positional argv, which would leak via
# /proc/<pid>/cmdline. So we mirror linkding's env-not-argv approach by hand:
#   - the plaintext ${ADMIN_PASSWORD} reaches Python ONLY via an environment var
#     (FB_SEED_PASSWORD), never on any command line;
#   - Python computes a bcrypt hash (Go's bcrypt accepts the $2b$ prefix);
#   - we write a 0600 `users import` JSON whose `password` field is that HASH (the
#     import does NOT re-hash — it stores the field verbatim), then import it.
# The only thing on argv is the JSON file PATH, which is not a secret. The 0600
# import file holds a bcrypt hash (not the plaintext) and is deleted right after.
# == Reviewers: verify (a) plaintext never on argv, (b) import file is 0600 +
#    removed, (c) the seed is gated on a FRESH db. ==
if [ "${db_existed}" -eq 1 ]; then
  ok "File Browser db already present at ${DB_BACKING}/filebrowser.db — NOT re-seeding the admin (idempotent)"
else
  FB_ADMIN_USER="${ADMIN_USER:-admin}"
  SEED_JSON="${DB_MOUNT}/.users-seed.json"   # written inside the bind-mounted ext4 db dir
  say "seeding the initial File Browser admin '${FB_ADMIN_USER}' (off-argv via a 0600 import file)"

  # Pass the plaintext to the userland ONLY through the environment (FB_SEED_PASSWORD),
  # never on argv. Python bcrypt-hashes it and writes the import JSON (0600). The
  # import file is removed immediately afterward (and again in a trap-free explicit
  # cleanup below). `users import` reads `password` as a pre-computed bcrypt hash.
  proot-distro login debian \
    --bind "${DB_BACKING}:${DB_MOUNT}" \
    -- env FB_SEED_PASSWORD="${ADMIN_PASSWORD}" FB_SEED_USER="${FB_ADMIN_USER}" \
       bash -lc '
      set -e
      umask 077
      # Need a bcrypt implementation. Prefer python3-bcrypt; fall back to passlib.
      python3 - "'"${SEED_JSON}"'" <<'"'"'PY'"'"'
import json, os, sys
pw = os.environ["FB_SEED_PASSWORD"].encode()          # plaintext from env, NEVER argv
user = os.environ["FB_SEED_USER"]
out = sys.argv[1]
try:
    import bcrypt
    h = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()  # $2b$… — accepted by Go bcrypt
except ImportError:
    from passlib.hash import bcrypt as _b
    h = _b.hash(pw)
# users import expects a JSON array; id 0 => create new. perm.admin grants admin.
doc = [{
    "id": 0,
    "username": user,
    "password": h,           # bcrypt HASH (import stores it verbatim; no re-hash)
    "lockPassword": False,
    "perm": {
        "admin": True, "execute": False, "create": True, "rename": True,
        "modify": True, "delete": True, "share": True, "download": True
    }
}]
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(doc, f)
PY
      chmod 600 "'"${SEED_JSON}"'"
      "'"${BIN}"'" -d "'"${DB_FILE}"'" users import "'"${SEED_JSON}"'"
      rm -f "'"${SEED_JSON}"'"
    ' 2>&1 | grep -v 'proot warning' \
    || { rm -f "${DB_BACKING}/.users-seed.json" 2>/dev/null || true; die "File Browser admin seed failed (need python3 + python3-bcrypt or python3-passlib inside the userland; see docs/FILES.md)"; }

  # Belt-and-braces: ensure the import file is gone from the host-visible ext4 dir.
  rm -f "${DB_BACKING}/.users-seed.json" 2>/dev/null || true
  ok "seeded File Browser admin '${FB_ADMIN_USER}' (password from .env ADMIN_PASSWORD — change after first login)"
fi

# Harden the db perms (defence in depth): the BoltDB holds accounts + share secrets.
chmod 600 "${DB_BACKING}/filebrowser.db" 2>/dev/null || true

# ── 5. Caddy vhost → /etc/caddy/apps/filebrowser.caddy (validate fail-closed) ─
# A self-contained site block so enabling File Browser never requires hand-editing
# the core Caddyfile (it imports /etc/caddy/apps/*.caddy). The listener style MUST
# match the other vhosts: explicit `http://<host>:${CADDY_PORT}` + `bind
# ${CADDY_BIND}` (plain HTTP on the shared high loopback port; the Cloudflare
# Tunnel terminates public TLS). The explicit http:// scheme stops Caddy inferring
# HTTPS-on-:443, which an unprivileged proot Caddy cannot bind.
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, and ${FB_PORT}.
say "writing the File Browser vhost to /etc/caddy/apps/filebrowser.caddy in the userland"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/filebrowser.caddy' <<EOF
# files.${DOMAIN} — File Browser (classic v2 web file manager).
# Written by scripts/apps/filebrowser.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here and (by default) Cloudflare Access gates the
# hostname at the edge — see docs/APP_AUTH.md / docs/FILES.md.
http://files.${DOMAIN}:${CADDY_PORT} {
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
	# Access at the edge and File Browser keeps its own native login
	# (auth.method=json). To front File Browser with the Matrix-SSO gateway
	# instead, you must ALSO switch File Browser to proxy auth so it trusts an
	# upstream username header:
	#     filebrowser -d <db> config set --auth.method=proxy --auth.header=Remote-User
	# === SECURITY (proxy auth): with auth.method=proxy + auth.header=Remote-User,
	# WHOEVER sets the Remote-User header IS that user — so the
	# `request_header -Remote-User` strip below is MANDATORY and MUST run BEFORE
	# forward_auth. Without it, a client can forge `Remote-User: admin` and walk
	# straight in as admin. The three parts below MUST precede the catch-all
	# reverse_proxy: the /authgw/* handler keeps the login form reachable (else
	# the 302-to-login loops), the request_header strips any client-forged
	# Remote-User before the gate, and forward_auth then gates everything else and
	# re-injects the verified Remote-User. ===
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

	# Everything → the File Browser backend on loopback.
	reverse_proxy 127.0.0.1:${FB_PORT}
}
EOF
then
  die "failed to write /etc/caddy/apps/filebrowser.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so we
# never leave a broken edge config in place.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/filebrowser.caddy"
ok "File Browser vhost written + Caddyfile validates"

# NOTE: we do NOT restart Caddy here. During a full install the stack is started
# afterward (scripts/start-stack.sh). If the stack is ALREADY running, the new
# vhost is not live until Caddy reloads — see the closing notes.

# ── 6. Supervise File Browser on loopback ────────────────────────────────────
# Two bind mounts: the ext4 db dir (so the BoltDB never lands on exFAT) and the
# exFAT content tree at /data (the root scope). -a 127.0.0.1 / -p ${FB_PORT} are
# passed EXPLICITLY even though loopback is the v2 default, so a future default
# change can't silently expose the service. -r /data is the served root. The lib's
# supervisor respawns it on crash with an identity-checked pidfile.
say "supervising File Browser (Go binary in the userland, bind 127.0.0.1:${FB_PORT})"
supervise filebrowser -- \
  proot-distro login debian \
  --bind "${CONTENT_BACKING}:${CONTENT_MOUNT}" \
  --bind "${DB_BACKING}:${DB_MOUNT}" \
  -- "${BIN}" -a 127.0.0.1 -p "${FB_PORT}" -d "${DB_FILE}" -r "${CONTENT_MOUNT}"

# ── 7. Best-effort health check ──────────────────────────────────────────────
# The Go binary + proot cold start can take a few seconds; poll the loopback port.
# A non-200 here is a WARNING (the supervisor keeps retrying), not fatal.
say "waiting for File Browser to answer on 127.0.0.1:${FB_PORT}"
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:${FB_PORT}/" >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "File Browser healthy on 127.0.0.1:${FB_PORT}"
else
  warn "File Browser not yet answering on :${FB_PORT} — check ${POCKET_LOG_DIR}/filebrowser.log (the supervisor keeps retrying)"
fi

# ── 8. Closing notes (manual Cloudflare + hardening) ─────────────────────────
cat >&2 <<EOF

$(ok "File Browser installed + supervised on 127.0.0.1:${FB_PORT}" 2>&1)

  Initial admin: '${ADMIN_USER:-admin}' (password from .env ADMIN_PASSWORD) —
  CHANGE IT after first login (it is only seeded on a fresh database).

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${FB_HOST}  ->  http://localhost:${CADDY_PORT}
       (the tunnel's local service is this phone's loopback Caddy edge; plain
        HTTP — the tunnel terminates public TLS).
    2. Cloudflare Access: add an Access application/policy covering
         ${FB_HOST}
       so only people you allow can reach File Browser. By default this is the
       outer gate; File Browser's own json login is the inner gate.

  Upload size: Cloudflare Tunnel caps a single request body at ~100MB, so a
  browser upload larger than ~100MB will fail at the edge. For large/bulk
  transfers use Syncthing or Dufs instead (see docs/FILES.md).

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).

  Optional Matrix-SSO front door: see the commented proxy-auth block in
  /etc/caddy/apps/filebrowser.caddy (NOTE the mandatory request_header strip) and
  docs/APP_AUTH.md.
EOF

ok "apps/filebrowser.sh done (files.${DOMAIN} once the Cloudflare hostname + Access policy are added)"
