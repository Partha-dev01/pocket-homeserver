#!/usr/bin/env bash
#
# apps/forgejo.sh — install + supervise Forgejo (the self-hosted, soft-fork-of-Gitea
# git forge) as an OPTIONAL app behind the loopback Caddy edge, on git.${DOMAIN}.
#
# Forgejo ships a single static Go binary per arch (a RAW binary download, NOT a
# tarball). We fetch the pinned linux-arm64 binary (exact version + sha256, a
# fail-closed supply-chain check), install it -m0755 into the userland at
# /opt/forgejo/forgejo, pre-seed a hardened app.ini on ext4, supervise `forgejo web`
# on loopback 127.0.0.1:9128, and front it with the core Caddy on git.${DOMAIN}.
#
# ┌── NETWORK TIER — READ THIS ─────────────────────────────────────────────────
# │ We pin [server] HTTP_ADDR=127.0.0.1 in app.ini so Forgejo's web server binds
# │ loopback ONLY. proot shares the phone's network namespace, so a wildcard bind
# │ here = reachable on the phone's REAL Wi-Fi/cellular interfaces (the verified
# │ past-outage class on this stack). We (1) assert HTTP_ADDR=127.0.0.1 in the
# │ rendered app.ini fail-closed AND (2) do a navidrome-style POST-START `ss`
# │ wildcard check on :9128 — if anything is listening on 0.0.0.0/[::]/* for the
# │ port we unsupervise + die rather than leave a LAN-exposed forge running.
# └─────────────────────────────────────────────────────────────────────────────
#
# ┌── STORAGE TIER — READ THIS ─────────────────────────────────────────────────
# │ Forgejo keeps its SQLite DB (forgejo.db + -wal/-shm), the git REPOSITORIES,
# │ LFS, attachments, avatars, indexers, sessions, logs and app.ini ALL on ext4 at
# │ $HOME/.pocket/forgejo (bind-mounted into the userland). SQLite WAL + git's pack
# │ writes need real fsync + atomic rename + POSIX locks, which the exFAT SD card
# │ does NOT provide → corruption. This script REFUSES to put the data dir under
# │ DATA_DIR (exFAT) fail-closed. Forgejo has NO read-mostly bulk tier worth putting
# │ on the SD (repos are write-heavy), so nothing here goes on the card.
# └─────────────────────────────────────────────────────────────────────────────
#
# ┌── RUN-AS-USER — READ THIS ──────────────────────────────────────────────────
# │ Forgejo REFUSES to run as root (Gitea/Forgejo abort with "Forgejo is not
# │ supposed to be run as root"). The proot-Debian userland logs in as root by
# │ default, so we run the server (and the admin-create CLI) as a dedicated
# │ unprivileged userland user, and pin RUN_USER in app.ini to match. The whole
# │ ext4 data dir is chown'd to that user so SQLite + git can write.
# └─────────────────────────────────────────────────────────────────────────────
#
# FIRST ADMIN: [security] INSTALL_LOCK=true disables the web installer, so there is
# no first-run wizard to create the first admin. We seed it from the CLI with
# `forgejo admin user create --admin --username … --email … --random-password`
# (run_once, idempotent) and capture the printed random password into a 0600 secrets
# file (${DATA_DIR}/secrets/forgejo.env) — the password is NEVER passed on argv.
#
# AUTH MODEL — sharp edge: by DEFAULT git.${DOMAIN} is gated at the Cloudflare edge
# (Cloudflare Access) and Forgejo keeps its OWN native login. The optional Matrix-SSO
# forward_auth gate (commented block) would cover ONLY the browser UI. BUT git-over-
# HTTP clients (`git clone/push https://…`) and API/token clients (/api/v1, the LFS
# batch API) send Basic/token auth and CANNOT follow a 302-to-login — so you MUST give
# git.${DOMAIN} a Cloudflare Access SERVICE-TOKEN exemption (or a path bypass for the
# git-http + /api/v1 + LFS paths). SSH access is DISABLED here (no public TCP on a
# CGNAT phone), so HTTPS is the only git transport. See docs/FORGEJO.md + docs/APP_AUTH.md.
#
# Generalized from the navidrome/dufs/vaultwarden app patterns; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_FORGEJO=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT Forgejo version + sha256 (the bare hex sha256sum of the raw
# linux-arm64 binary) rather than tracking "latest", so the download fails closed on
# any corruption/tampering. Both are env-overridable (and centrally pinned in
# config/versions.env) without editing this file.
#
# To upgrade: bump FORGEJO_VER and FORGEJO_SHA256 *together* (Forgejo publishes a
# per-asset <binary>.sha256 alongside each release; verify it, or hash a binary you
# already trust: sha256sum forgejo-<ver>-linux-arm64). Forgejo's data (DB + repos +
# app.ini) persists across upgrades because it lives on ext4 at $HOME/.pocket/forgejo.
# DB migrations auto-run on first start of a new version and are NOT auto-reversible —
# back up $HOME/.pocket/forgejo FIRST (see the closing notes).
FORGEJO_VER="${FORGEJO_VER:-15.0.3}"
FORGEJO_SHA256="${FORGEJO_SHA256:-788ffe2fdbebff177f5bc73d54ef1827ab0d5704813b97cb22590602427e9af4}"
FORGEJO_ARCH="arm64"
FORGEJO_ASSET="forgejo-${FORGEJO_VER}-linux-${FORGEJO_ARCH}"   # a RAW binary, NOT a tarball
FORGEJO_URL="${FORGEJO_URL:-https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VER}/${FORGEJO_ASSET}}"

# ── Service coordinates ──────────────────────────────────────────────────────
FORGEJO_PORT="${FORGEJO_PORT:-9128}"      # loopback bind; only Caddy reaches it
FORGEJO_HOST="git.${DOMAIN}"              # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/forgejo                   # in userland — the binary
BIN="${INSTALL_DIR}/forgejo"               # in userland — /opt/forgejo/forgejo
DATA_MOUNT="${INSTALL_DIR}/data"           # in userland — bind target (ALL state: db/repos/app.ini)
APP_INI="${DATA_MOUNT}/app.ini"            # in userland (ext4 bind) — chmod 600
# The dedicated unprivileged userland user Forgejo runs as (it refuses to run as root).
FORGEJO_RUN_USER="${FORGEJO_RUN_USER:-forgejo}"

# ── Storage tiers ────────────────────────────────────────────────────────────
# ALL state on ext4 (NOT exFAT): forgejo.db + -wal/-shm, git repos, LFS, attachments,
# avatars, indexers, sessions, logs, app.ini. SQLite WAL + git packs need real fsync +
# atomic rename + POSIX locks. The whole ext4 tree is bind-mounted to ${DATA_MOUNT}.
DATA_BACKING="${HOME}/.pocket/forgejo"     # on ext4 (host) — survives a rootfs rebuild
CACHE_DIR="${DATA_DIR}/binaries"
FORGEJO_LOCAL="${CACHE_DIR}/${FORGEJO_ASSET}"
# The first-admin credential (cleartext, generated by the CLI) lives here, 0600.
SECRETS_FILE="${DATA_DIR}/secrets/forgejo.env"

# ── Data dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ───────────────────
# The SQLite DB + WAL + the git repositories MUST stay on ext4; exFAT would corrupt
# them. Refuse the same way vaultwarden.sh / navidrome.sh do.
assert_ext4 "${DATA_BACKING}" "Forgejo data dir"
mkdir -p "${DATA_BACKING}" "${CACHE_DIR}" "${DATA_DIR}/secrets" || die "cannot create ${DATA_BACKING} on ext4"
chmod 700 "${DATA_BACKING}" "${DATA_DIR}/secrets" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Download the RAW arm64 binary, sha256-verified fail-closed ────────────
# fetch_verified (from common.sh) reuses a cached copy that already matches the pin,
# and deletes + aborts on any mismatch. The asset is a raw ELF binary (no archive).
fetch_verified "${FORGEJO_URL}" "${FORGEJO_LOCAL}" "${FORGEJO_SHA256}"
ok "Forgejo v${FORGEJO_VER} binary ready at ${FORGEJO_LOCAL} ($(wc -c < "${FORGEJO_LOCAL}") bytes)"

# ── 2. Install the binary -m0755 into the userland + verify it runs ──────────
# proot-distro manages the rootfs path, so go through `proot-distro login` and stream
# the binary in over stdin into install(1) (no hardcoded rootfs location). Because it
# is a raw binary (not a tarball), `install` both copies and sets the 0755 mode.
say "installing the Forgejo binary into the userland (${BIN})"
in_debian "mkdir -p ${INSTALL_DIR}"
proot-distro login debian -- bash -lc "install -m 0755 /dev/stdin ${BIN}" \
  < "${FORGEJO_LOCAL}" || die "failed to install the Forgejo binary into the userland at ${BIN}"
in_debian "[ -x ${BIN} ]" || die "Forgejo binary missing/not executable after install at ${BIN}"
ver="$(in_debian "${BIN} --version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "Forgejo: ${ver}" || warn "forgejo --version produced no output (continuing; the supervisor will surface a real boot failure)"

# ── 3. Runtime deps + the dedicated unprivileged run user ────────────────────
# Forgejo's git backend needs `git`; the binary is otherwise self-contained. It
# REFUSES to run as root, so create an unprivileged userland user to run as. Both are
# idempotent. (git is usually present in the userland, but we ensure it fail-closed.)
say "ensuring git + the unprivileged run user '${FORGEJO_RUN_USER}' exist in the userland"
in_debian "command -v git >/dev/null 2>&1" \
  || in_debian "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y --no-install-recommends git ca-certificates" \
  || die "failed to install git in the userland — Forgejo needs it"
in_debian "id -u '${FORGEJO_RUN_USER}' >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash '${FORGEJO_RUN_USER}'" \
  || die "failed to create the unprivileged run user '${FORGEJO_RUN_USER}' in the userland"
ok "git present + run user '${FORGEJO_RUN_USER}' exists"

# ── 4. Data dir bind target in the userland + ownership ──────────────────────
# The ext4 backing dir is bind-mounted to ${DATA_MOUNT} at start time; create the
# in-userland mountpoint now. Ownership (chown to the run user) is applied AT START
# (step 8's launcher) because the bind is only live then.
in_debian "mkdir -p ${DATA_MOUNT}" || die "failed to create the ${DATA_MOUNT} mountpoint in the userland"

# ── 5. Generate the SECRET_KEY + INTERNAL_TOKEN off-argv, persisted 0600 ─────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ Forgejo needs a stable SECRET_KEY (cookie/2FA secret) and INTERNAL_TOKEN
# │ (internal API auth) in app.ini. If absent, Forgejo auto-generates them on first
# │ start and REWRITES app.ini — which races our hardening and can flip values. We
# │ generate them OURSELVES, off-argv, with `forgejo generate secret` inside the
# │ userland (output captured to a host var, never echoed, never on a command line),
# │ and persist them in the 0600 ${SECRETS_FILE} so they are STABLE across re-runs
# │ (regenerating SECRET_KEY would invalidate every session + 2FA enrolment).
# └────────────────────────────────────────────────────────────────────────────
if [ -f "${SECRETS_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  say "reusing Forgejo SECRET_KEY / INTERNAL_TOKEN from ${SECRETS_FILE}"
fi
if [ -z "${FORGEJO_SECRET_KEY:-}" ] || [ -z "${FORGEJO_INTERNAL_TOKEN:-}" ]; then
  say "generating Forgejo SECRET_KEY + INTERNAL_TOKEN (off-argv, inside the userland)"
  # `forgejo generate secret SECRET_KEY` / `… INTERNAL_TOKEN` print one token to
  # stdout. Captured into host vars — never echoed, never on argv.
  FORGEJO_SECRET_KEY="$(in_debian "${BIN} generate secret SECRET_KEY 2>/dev/null | tr -d '\r\n'" || true)"
  FORGEJO_INTERNAL_TOKEN="$(in_debian "${BIN} generate secret INTERNAL_TOKEN 2>/dev/null | tr -d '\r\n'" || true)"
  [ -n "${FORGEJO_SECRET_KEY}" ]    || die "failed to generate Forgejo SECRET_KEY in the userland"
  [ -n "${FORGEJO_INTERNAL_TOKEN}" ] || die "failed to generate Forgejo INTERNAL_TOKEN in the userland"
  umask 077
  # QUOTED heredoc — the tokens are written verbatim, never expanded by the shell.
  cat > "${SECRETS_FILE}" <<'SECRETS'
# Forgejo internal secrets — generated by apps/forgejo.sh. PRIVATE (chmod 600).
# SECRET_KEY signs cookies + 2FA; INTERNAL_TOKEN authenticates Forgejo's internal
# API. Rotating SECRET_KEY invalidates every session + 2FA enrolment — keep stable.
# The first-admin LOGIN credential (username/password) is appended below by the
# admin-create step. Deleting this file regenerates the secrets on the next run
# (and will break existing sessions/2FA).
SECRETS
  {
    printf 'FORGEJO_SECRET_KEY=%s\n' "${FORGEJO_SECRET_KEY}"
    printf 'FORGEJO_INTERNAL_TOKEN=%s\n' "${FORGEJO_INTERNAL_TOKEN}"
  } >> "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
  ok "generated Forgejo SECRET_KEY + INTERNAL_TOKEN → ${SECRETS_FILE} (chmod 600)"
fi

# ── 6. Pre-seed a hardened 0600 app.ini (loopback, registration off, no SSH) ─
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ HTTP_ADDR=127.0.0.1 forces loopback (the real outage guard; asserted below +
# │ ss-checked post-start). INSTALL_LOCK=true disables the web installer. RUN_USER
# │ MUST match the OS user we launch as (Forgejo cross-checks it). DISABLE_REGISTRATION
# │ =true → invite/admin-only accounts. DISABLE_SSH + START_SSH_SERVER off → no SSH
# │ transport (a CGNAT phone has no public TCP). actions ENABLED=false → no CI runners.
# │ All paths live under the ext4 bind (${DATA_MOUNT}). The two secrets come from the
# │ 0600 secrets file (expanded by the host shell into the heredoc — they are not
# │ logged). Idempotent: if a hardened app.ini with the loopback bind already exists
# │ we KEEP it (never clobber operator edits / Forgejo rewrites) and only re-assert.
# │ Keys verified against Forgejo's config cheat-sheet for the 15.x series.
# └────────────────────────────────────────────────────────────────────────────
if in_debian "[ -f '${APP_INI}' ]" \
   && in_debian "grep -Eq '^[[:space:]]*HTTP_ADDR[[:space:]]*=[[:space:]]*127\.0\.0\.1[[:space:]]*\$' '${APP_INI}'"; then
  ok "existing hardened app.ini found (loopback bind) — keeping it"
else
  say "pre-seeding the hardened ${APP_INI} (chmod 600; loopback bind; registration off; no SSH)"
  # UNQUOTED heredoc so the shell expands our vars (incl. the two secrets from the
  # 0600 file). Written with umask 077 inside the userland; chmod 600 after.
  proot-distro login debian -- bash -lc "umask 077; cat > '${APP_INI}'" <<EOF
; Generated by apps/forgejo.sh — hardened, single-tenant Forgejo config.
; Forgejo v${FORGEJO_VER}. Loopback-only; the core Caddy + the Cloudflare Tunnel
; terminate the public edge. ALL paths under the ext4 bind (${DATA_MOUNT}).
APP_NAME = pocket-homeserver git
; The OS user Forgejo runs as — MUST match the launcher (it refuses to run as root).
RUN_USER = ${FORGEJO_RUN_USER}
RUN_MODE = prod
WORK_PATH = ${DATA_MOUNT}

[server]
; ── loopback bind (do NOT change — proot shares the phone's network namespace) ──
PROTOCOL = http
HTTP_ADDR = 127.0.0.1
HTTP_PORT = ${FORGEJO_PORT}
ROOT_URL = https://${FORGEJO_HOST}/
DOMAIN = ${FORGEJO_HOST}
; ── SSH disabled: a CGNAT phone has no public TCP; HTTPS is the only git transport ──
DISABLE_SSH = true
START_SSH_SERVER = false
LFS_START_SERVER = true
APP_DATA_PATH = ${DATA_MOUNT}/data
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = ${DATA_MOUNT}/data/forgejo.db
; WAL keeps SQLite happy under concurrent reads (ext4 only — never exFAT).
SQLITE_JOURNAL_MODE = WAL

[repository]
ROOT = ${DATA_MOUNT}/repositories
DEFAULT_BRANCH = main

[lfs]
PATH = ${DATA_MOUNT}/data/lfs

[security]
; No web installer (we seed the first admin via the CLI). Off-argv generated secrets.
INSTALL_LOCK = true
SECRET_KEY = ${FORGEJO_SECRET_KEY}
INTERNAL_TOKEN = ${FORGEJO_INTERNAL_TOKEN}
; A token client could otherwise spoof the reverse-proxy login header — keep this off.
REVERSE_PROXY_AUTHENTICATION_USER =

[service]
; Invite/admin-only — no open registration; CAPTCHA + email confirm off (single-tenant).
DISABLE_REGISTRATION = true
REGISTER_EMAIL_CONFIRM = false
ENABLE_NOTIFY_MAIL = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = false
ENABLE_CAPTCHA = false
DEFAULT_KEEP_EMAIL_PRIVATE = true
DEFAULT_ALLOW_CREATE_ORGANIZATION = true

[actions]
; No CI runners on a phone (thermal / low-memory-killer heavy path).
ENABLED = false

[session]
PROVIDER = file
PROVIDER_CONFIG = ${DATA_MOUNT}/data/sessions
COOKIE_SECURE = true

[log]
MODE = file
LEVEL = Info
ROOT_PATH = ${DATA_MOUNT}/log

[indexer]
ISSUE_INDEXER_PATH = ${DATA_MOUNT}/indexers/issues.bleve

[attachment]
PATH = ${DATA_MOUNT}/data/attachments

[picture]
AVATAR_UPLOAD_PATH = ${DATA_MOUNT}/data/avatars
REPOSITORY_AVATAR_UPLOAD_PATH = ${DATA_MOUNT}/data/repo-avatars

[other]
SHOW_FOOTER_VERSION = false
EOF
  in_debian "chmod 600 '${APP_INI}' && chown '${FORGEJO_RUN_USER}:${FORGEJO_RUN_USER}' '${APP_INI}'" || true
  ok "wrote ${APP_INI} (chmod 600, HTTP_ADDR=127.0.0.1, INSTALL_LOCK=true, no SSH, registration off)"
fi

# ── 7. FAIL-CLOSED loopback assert (config) ──────────────────────────────────
# Refuse to start a LAN-exposed forge: require the loopback bind AND reject a
# 0.0.0.0/:: bind outright. (The post-start ss check in step 10 is the second layer.)
say "asserting the Forgejo bind is loopback in app.ini"
in_debian "grep -Eq '^[[:space:]]*HTTP_ADDR[[:space:]]*=[[:space:]]*127\.0\.0\.1[[:space:]]*\$' '${APP_INI}'" \
  || die "HTTP_ADDR is NOT 127.0.0.1 in app.ini — refusing to start a LAN-exposed forge (check ${APP_INI})"
in_debian "grep -Eq '^[[:space:]]*HTTP_ADDR[[:space:]]*=[[:space:]]*(0\.0\.0\.0|::|\*)' '${APP_INI}'" \
  && die "Forgejo app.ini binds a wildcard address — refusing to start (check ${APP_INI})" || true
in_debian "grep -Eq '^[[:space:]]*INSTALL_LOCK[[:space:]]*=[[:space:]]*true[[:space:]]*\$' '${APP_INI}'" \
  || die "INSTALL_LOCK is not true — refusing to start with the web installer open"
ok "Forgejo bind confirmed loopback (127.0.0.1); INSTALL_LOCK=true"

# In-userland launcher: ensure the ext4 bind is owned by the run user (so SQLite +
# git can write), then drop privileges and exec `forgejo web` as that user with the
# explicit config + work path. Forgejo refuses to run as root, hence `su`. No secrets
# on argv — they live in the 0600 app.ini. GITEA_WORK_DIR keeps tooling that ignores
# WORK_PATH consistent.
proot-distro login debian -- bash -lc "umask 077; cat > '${INSTALL_DIR}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/forgejo.sh.
# Forgejo binds 127.0.0.1:${FORGEJO_PORT}; DB/repos/app.ini on the ext4 bind.
set -e
# The bind is only live now; make the whole data tree owned by the unprivileged
# run user (Forgejo refuses to run as root + SQLite/git must be able to write).
chown -R '${FORGEJO_RUN_USER}:${FORGEJO_RUN_USER}' '${DATA_MOUNT}' 2>/dev/null || true
export GITEA_WORK_DIR='${DATA_MOUNT}'
# Drop to the unprivileged user and exec the web server with the explicit config.
exec su -s /bin/bash '${FORGEJO_RUN_USER}' -c \
  "exec env GITEA_WORK_DIR='${DATA_MOUNT}' '${BIN}' web --config '${APP_INI}' --work-path '${DATA_MOUNT}'"
LAUNCH
in_debian "chmod +x '${INSTALL_DIR}/run.sh'" || die "failed to make ${INSTALL_DIR}/run.sh executable"

# ── 8. Caddy vhost → /etc/caddy/apps/forgejo.caddy (validate fail-closed) ────
# A self-contained site block so enabling Forgejo never requires hand-editing the
# core Caddyfile (it imports /etc/caddy/apps/*.caddy). The listener style MUST match
# the other vhosts: explicit `http://<host>:${CADDY_PORT}` + `bind ${CADDY_BIND}`
# (plain HTTP on the shared high loopback port; the Cloudflare Tunnel terminates
# public TLS).
#
# A FORGE needs large request bodies (git push packs, LFS uploads) — flush_interval
# -1 streams without buffering and the generous transport timeouts keep big transfers
# alive. Mind the Cloudflare Tunnel ~100MB single-request body cap (git http pushes
# split into chunks; an LFS object > 100MB needs a different path — see docs).
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, and ${FORGEJO_PORT}.
say "writing the Forgejo vhost to /etc/caddy/apps/forgejo.caddy in the userland"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/forgejo.caddy' <<EOF
# git.${DOMAIN} — Forgejo (self-hosted git forge).
# Written by scripts/apps/forgejo.sh. Loopback-only; the Cloudflare Tunnel forwards
# public traffic here and (by default) Cloudflare Access gates the hostname at the
# edge — but git-over-HTTP (git clone/push) and /api/v1 + LFS token clients CANNOT
# follow a 302 login, so you MUST give git.${DOMAIN} a CF Access SERVICE-TOKEN
# exemption (or a path bypass for the git-http/API/LFS paths). SSH is disabled (a
# CGNAT phone has no public TCP). See docs/FORGEJO.md + docs/APP_AUTH.md.
http://git.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md).
	# By default this stays COMMENTED OUT: the hostname is gated by Cloudflare Access
	# at the edge and Forgejo keeps its own native login. NOTE: fronting Forgejo with
	# the interactive Matrix-SSO gate BREAKS git-over-HTTP + /api/v1 + LFS clients
	# (they cannot follow a 302); it would only work for the browser UI. If you enable
	# it anyway, the three parts MUST precede the reverse_proxy below — the /authgw/*
	# handler keeps the login form reachable (else the 302-to-login loops), the
	# request_header strips any client-forged Remote-User before the gate (defense in
	# depth: REVERSE_PROXY_AUTHENTICATION_USER is also unset in app.ini), and
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

	# Everything → the Forgejo backend on loopback. flush_interval -1 streams large
	# git packs + LFS uploads without buffering; generous timeouts keep them alive.
	reverse_proxy 127.0.0.1:${FORGEJO_PORT} {
		flush_interval -1
		transport http {
			dial_timeout 10s
			response_header_timeout 5m
			read_timeout 0
			write_timeout 0
		}
	}
}
EOF
then
  die "failed to write /etc/caddy/apps/forgejo.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so we
# never leave a broken edge config in place.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/forgejo.caddy"
ok "Forgejo vhost written + Caddyfile validates"

# NOTE: we do NOT restart Caddy here. During a full install the stack is started
# afterward (scripts/start-stack.sh). If the stack is ALREADY running, the new vhost
# is not live until Caddy reloads — see the closing notes.

# ── 9. Supervise Forgejo on loopback ─────────────────────────────────────────
# The ext4 data dir is bind-mounted so forgejo.db + WAL + the git repos land on a
# real filesystem. The launcher chowns the bind, drops to the unprivileged run user,
# and exec's `forgejo web`. The shared supervisor respawns it on crash with an
# identity-checked pidfile and records the exact argv for a drift-free restart.
say "supervising Forgejo (Go binary in the userland, bind 127.0.0.1:${FORGEJO_PORT})"
supervise forgejo -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- bash "${INSTALL_DIR}/run.sh"

# ── 10. FAIL-CLOSED post-start loopback assert (navidrome-style ss check) ────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ Second layer beyond the app.ini assert: once the server is up, confirm via `ss`
# │ that NOTHING is listening on a WILDCARD (0.0.0.0 / [::] / *) for ${FORGEJO_PORT}.
# │ If a wildcard listener exists we unsupervise + die rather than leave a LAN-exposed
# │ forge running. We poll briefly (the Go cold start + DB migration can take a few
# │ seconds) for the loopback listener to appear; absence of a wildcard is the gate.
# │ `ss -ltnH` is checked first (Termux/proot usually has iproute2); we fall back to
# │ parsing the listener some other way only if `ss` is unavailable (then we WARN, as
# │ we cannot positively assert). proot shares the host net ns, so a wildcard here =
# │ the phone's real interfaces.
# └────────────────────────────────────────────────────────────────────────────
say "post-start: asserting nothing is listening on a wildcard for :${FORGEJO_PORT} (ss check)"
ss_bin=""
command -v ss >/dev/null 2>&1 && ss_bin="$(command -v ss)"
if [ -z "${ss_bin}" ]; then
  # ss is in the userland's iproute2 even when absent on the Termux host.
  in_debian 'command -v ss >/dev/null 2>&1' && ss_bin="in_debian"
fi
ss_dump() {
  if [ "${ss_bin}" = "in_debian" ]; then in_debian "ss -ltnH 2>/dev/null"; else "${ss_bin}" -ltnH 2>/dev/null; fi
}
if [ -n "${ss_bin}" ]; then
  loop_up=0
  for _ in $(seq 1 30); do
    dump="$(ss_dump || true)"
    # A wildcard listener for our port: "0.0.0.0:9128", "*:9128", "[::]:9128", ":::9128".
    if printf '%s\n' "${dump}" | grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):${FORGEJO_PORT}([[:space:]]|\$)"; then
      unsupervise forgejo
      die "Forgejo is listening on a WILDCARD address for :${FORGEJO_PORT} — refusing to leave a LAN-exposed forge running (check ${APP_INI} HTTP_ADDR). Stopped the service."
    fi
    # Confirm the loopback listener is up (positive liveness for the assert).
    if printf '%s\n' "${dump}" | grep -Eq "(^|[[:space:]])(127\.0\.0\.1|\[::1\]):${FORGEJO_PORT}([[:space:]]|\$)"; then
      loop_up=1; break
    fi
    sleep 1
  done
  if [ "${loop_up}" -eq 1 ]; then
    ok "Forgejo listening on loopback only for :${FORGEJO_PORT} (no wildcard) — confirmed"
  else
    # Re-check once for a wildcard even if loopback hasn't shown yet, then warn.
    if printf '%s\n' "$(ss_dump || true)" | grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):${FORGEJO_PORT}([[:space:]]|\$)"; then
      unsupervise forgejo
      die "Forgejo is listening on a WILDCARD address for :${FORGEJO_PORT} — refusing to leave a LAN-exposed forge running. Stopped the service."
    fi
    warn "could not yet observe a :${FORGEJO_PORT} listener via ss (slow Go cold start / DB migration); no wildcard seen. Re-check with: ss -ltn | grep ${FORGEJO_PORT}"
  fi
else
  warn "ss not available on host or in the userland — could NOT positively assert the bind. Verify manually: ss -ltn | grep ${FORGEJO_PORT} shows ONLY 127.0.0.1:${FORGEJO_PORT}"
fi

# ── 11. Seed the first admin via the CLI (run_once; password off-argv) ───────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ INSTALL_LOCK=true means no web installer, so we create the first admin from the
# │ CLI: `forgejo admin user create --admin --username … --email … --random-password`.
# │ --random-password makes Forgejo GENERATE the password and print it to stdout, so
# │ we never put a real password on argv (which would show in `ps`). We run it as the
# │ run user (it touches the DB on the ext4 bind), capture stdout to a host var, parse
# │ the printed password, and append the credential to the 0600 ${SECRETS_FILE}. This
# │ is run_once so re-runs don't try to recreate the admin. The admin-create CLI is
# │ run via a one-shot `proot-distro login … --bind` so the same ext4 bind is present.
# └────────────────────────────────────────────────────────────────────────────
ADMIN_USER="${ADMIN_USER:-admin}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN}}"
seed_forgejo_admin() {
  # Run inside the userland AS the run user, with the ext4 data dir bound, capturing
  # the generated password from stdout. --must-change-password=false so the printed
  # password works directly. Output is captured (never streamed) so the secret does
  # not hit logs.
  local out
  out="$(proot-distro login debian \
        --bind "${DATA_BACKING}:${DATA_MOUNT}" \
        -- su -s /bin/bash "${FORGEJO_RUN_USER}" -c \
        "env GITEA_WORK_DIR='${DATA_MOUNT}' '${BIN}' admin user create \
           --admin --username '${ADMIN_USER}' --email '${FORGEJO_ADMIN_EMAIL}' \
           --random-password --must-change-password=false \
           --config '${APP_INI}' --work-path '${DATA_MOUNT}' 2>&1" || true)"
  # Forgejo prints a line like:  New user 'admin' has been successfully created!
  # and another like:            generated random password is 'XXXXXXXX'
  local pw
  pw="$(printf '%s\n' "${out}" | sed -nE "s/.*[Gg]enerated random password is[:[:space:]]*'?([^'[:space:]]+)'?.*/\1/p" | head -1)"
  if [ -z "${pw}" ]; then
    # Tolerate "already exists" as success-for-idempotency; otherwise fail loudly.
    if printf '%s\n' "${out}" | grep -qiE 'already exist'; then
      warn "Forgejo admin '${ADMIN_USER}' already exists — leaving it (no password reset)."
      return 0
    fi
    warn "could not parse the generated admin password from the CLI output:"
    printf '%s\n' "${out}" >&2
    return 1
  fi
  umask 077
  {
    printf '\n# First-admin login credential (generated %s) — give this to the operator.\n' "$(date -u +%FT%TZ)"
    printf 'FORGEJO_ADMIN_USER=%s\n' "${ADMIN_USER}"
    printf 'FORGEJO_ADMIN_EMAIL=%s\n' "${FORGEJO_ADMIN_EMAIL}"
    printf 'FORGEJO_ADMIN_PASSWORD=%s\n' "${pw}"
  } >> "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
  ok "created Forgejo admin '${ADMIN_USER}' — login credential saved to ${SECRETS_FILE} (chmod 600)"
}
run_once forgejo-admin -- seed_forgejo_admin \
  || warn "first-admin seeding did not complete (see above) — you can re-run it later: see docs/FORGEJO.md"

# ── 12. Best-effort health check ─────────────────────────────────────────────
# /api/healthz is an unauthenticated liveness endpoint (returns 200 with a JSON
# status) in the 15.x series. The Go cold start + first-run DB migration under proot
# can take a while; poll the loopback port. A non-200 here is a WARNING (the
# supervisor keeps retrying), not fatal.
say "waiting for Forgejo to answer on 127.0.0.1:${FORGEJO_PORT}"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${FORGEJO_PORT}/api/healthz" 2>/dev/null \
     || curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${FORGEJO_PORT}/" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 2
done
if [ "${healthy}" -eq 1 ]; then
  ok "Forgejo answering on 127.0.0.1:${FORGEJO_PORT}"
else
  warn "Forgejo not yet answering on :${FORGEJO_PORT} — check ${POCKET_LOG_DIR}/forgejo.log (the Go cold start + DB migration is slow; the supervisor keeps retrying)"
fi

# ── 13. Closing notes (manual Cloudflare + first-admin + upgrades) ───────────
cat >&2 <<EOF

$(ok "Forgejo installed + supervised on 127.0.0.1:${FORGEJO_PORT} (data on ${DATA_BACKING})" 2>&1)

  FIRST ADMIN: the web installer is locked (INSTALL_LOCK=true), so the first admin
  was created from the CLI. Its login credential is in:
         ${SECRETS_FILE}   (chmod 600)
    Read FORGEJO_ADMIN_USER / FORGEJO_ADMIN_PASSWORD there to log in at git.${DOMAIN},
    then change the password in the UI. Open registration is OFF (invite/admin-only).

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${FORGEJO_HOST}  ->  http://localhost:${CADDY_PORT}   (plain HTTP; the tunnel
       terminates public TLS).
    2. Cloudflare Access — GATE THE UI, EXEMPT THE GIT/API CLIENTS: add an Access
       application for ${FORGEJO_HOST} to gate the web UI, but git-over-HTTP
       (git clone/push), the REST API (/api/v1) and the LFS batch API send Basic/token
       auth and CANNOT complete an interactive Access login. Either add a CF Access
       SERVICE-TOKEN exemption for ${FORGEJO_HOST}, or add path BYPASS rules for the
       git-http + /api/v1 + LFS endpoints. Forgejo's own login/token is the real gate
       on those paths. See docs/FORGEJO.md + docs/APP_AUTH.md.

  SSH: disabled here (DISABLE_SSH=true, START_SSH_SERVER=false) — a CGNAT phone has no
  public TCP, so HTTPS is the only git transport (use a Forgejo access token as the
  git password). Upload cap: the Cloudflare Tunnel caps a single request body at
  ~100MB; git http pushes chunk fine, but a single LFS object >100MB needs another
  path. See docs/FORGEJO.md.

  Upgrades: back up ${DATA_BACKING} FIRST (scripts/ops/backup-db.sh covers the ext4
  $HOME/.pocket tree), then bump FORGEJO_VER + FORGEJO_SHA256 together (verify the
  per-asset .sha256 alongside the release) and re-run. The DB migrates on first start
  of a new version and is NOT auto-reversible.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).
EOF

ok "apps/forgejo.sh done (git.${DOMAIN} once the Cloudflare hostname + Access policy + git/API exemption are added)"

# Generalized from the navidrome/dufs/vaultwarden app patterns; review before running.
