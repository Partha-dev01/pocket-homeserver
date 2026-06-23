#!/usr/bin/env bash
#
# steps/86-install-webmail.sh — install + supervise the OPTIONAL SnappyMail
# WEBMAIL UI (the front door to the Maddy mailbox shipped by the email
# subsystem). php-fpm runs INSIDE the Debian userland on a dedicated loopback
# pool; Caddy fronts it with `php_fastcgi` at webmail.${DOMAIN}.
#
# It is a core step that SELF-GATES on ENABLE_EMAIL (install.sh runs it
# unconditionally; it no-ops unless you opt in), so a default install never
# touches it. ENABLE_EMAIL is the SAME flag the mail-server half (Maddy) uses;
# this is the UI half — it expects the Maddy IMAP (:${MAIL_IMAP_PORT}) /
# submission (:${MAIL_SUBMISSION_PORT}) listeners to exist on loopback.
#
# What it does (idempotent — safe to re-run):
#   1. installs php-fpm + the PHP extensions SnappyMail needs into the userland,
#   2. downloads + sha256-verifies the pinned SnappyMail release tarball and
#      extracts it to /opt/snappymail WITHOUT clobbering the data dir,
#   3. moves the data folder OUTSIDE the webroot (include.php) + writes a
#      dedicated php-fpm pool (loopback :${SNAPPYMAIL_FPM_PORT}),
#   4. writes the webmail Caddy vhost (http://webmail.${DOMAIN}:${CADDY_PORT} +
#      bind ${CADDY_BIND}) and validates the full Caddyfile fail-closed,
#   5. supervises php-fpm, bootstraps the data dir, then pins the domain to
#      mail.${DOMAIN} (loopback IMAP/SMTP) and drops the bundled public providers,
#   6. (if the Matrix-SSO gateway is on) deploys the login-matrix-oidc plugin +
#      ENABLES it in application.ini fail-closed (INSERT-missing-lines + verify),
#      wiring the client secret from a 0600 file,
#   7. (optional) host-locks SnappyMail's NATIVE admin panel to a dedicated
#      webmail-admin.${DOMAIN} vhost behind Cloudflare Access (ENABLE_WEBMAIL_ADMIN).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when explicitly enabled ──────────────────────────────
if [ "${ENABLE_EMAIL:-false}" != "true" ]; then
  ok "webmail disabled (ENABLE_EMAIL != true) — skipping (this is the default)"
  exit 0
fi

require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }
# Same, but with the SnappyMail data dir bind-mounted in. REQUIRED for any read or
# edit of the live data tree (configs/application.ini, domains/, plugins/, cache/):
# that tree lives on the large volume (SM_DATA_HOST) and is only visible inside the
# userland through this bind — each proot login is a fresh mount namespace, so a
# plain in_debian would see the empty rootfs mountpoint instead of the real data.
in_debian_data() { proot-distro login debian --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT upstream release (env-overridable) rather than a floating one, so
# an upgrade is a deliberate bump. This is a RELEASE asset (not a GitHub git
# auto-archive), so the bytes are stable. sha256 verified fail-closed inside the
# userland. To bump: set SNAPPYMAIL_VERSION + regenerate the hash with
#   curl -fsSL "$SNAPPYMAIL_URL" | sha256sum
SM_VER="${SNAPPYMAIL_VERSION:-2.38.2}"
SM_URL="${SNAPPYMAIL_URL:-https://github.com/the-djmaze/snappymail/releases/download/v${SM_VER}/snappymail-${SM_VER}.tar.gz}"
SM_SHA256="${SNAPPYMAIL_SHA256:-71f1d8a9065cc9cf7ddd064f5c47cc7b255cb70e6a56713647fc73d4b79e33ec}"

# ── Service-local config ─────────────────────────────────────────────────────
SM_WEBROOT="/opt/snappymail"                       # app root INSIDE the userland
SM_DATA_USERLAND="/opt/snappymail-data"            # data dir OUTSIDE the webroot (include.php)
SM_DDEF="${SM_DATA_USERLAND}/_data_/_default_"      # per-default-account dir (configs/plugins/cache)
SM_FPM_PORT="${SNAPPYMAIL_FPM_PORT:-9092}"          # dedicated php-fpm pool
SM_FPM_CONF="${SM_WEBROOT}/php-fpm.conf"            # pool config (in the userland)
SM_DATA_HOST="${DATA_DIR}/snappymail"               # data backing dir (large volume)
SM_HOST="webmail.${DOMAIN}"                         # public hostname (user webmail)
SM_ADMIN_HOST="webmail-admin.${DOMAIN}"             # public hostname (native admin panel)
MAIL_HOST="mail.${DOMAIN}"                          # the mailbox domain (Maddy)

# Maddy loopback ports — the SAME canonical names the mail-server half (steps/85)
# uses, so the two halves can never drift. The domain JSON points SnappyMail at the
# IMAP listener (incoming) and the outbound SUBMISSION listener (sending).
IMAP_PORT="${MAIL_IMAP_PORT:-9143}"
SMTP_PORT="${MAIL_SUBMISSION_PORT:-9587}"

# Maddy install dir inside the userland (used by the OIDC plugin's JIT provision).
# Fixed userland paths (steps/85 installs Maddy here), not .env-configurable.
MADDY_DIR="/opt/maddy"
MADDY_CONFIG="/opt/maddy/maddy.conf"

# Asset sources (this repo).
ASSET_DIR="${POCKET_ROOT}/scripts/email/snappymail"
PLUGIN_SRC="${ASSET_DIR}/plugins/login-matrix-oidc"

# Secrets dir on the large volume (0600 files; never on argv).
SECRETS_HOST="${DATA_DIR}/secrets/email"

# Where the plugin reads its OIDC client secret (in the userland data dir).
SM_OIDC_SECRET_FILE="${SM_DATA_USERLAND}/matrix-oidc-secret"

# ════════════════════════════════════════════════════════════════════════════
# SECURITY-CRITICAL helpers — each derives or places a credential, or enables auth
# fail-closed, where a silent no-op or a leaked secret would be an incident. Every
# secret is generated/handled off argv, persisted 0600, and reused on re-run; the
# auth-enable paths post-verify and return nonzero so the caller aborts.
# ════════════════════════════════════════════════════════════════════════════

# _provision_oidc_secret — ensure the OIDC client secret exists and is readable
# by the plugin at ${SM_OIDC_SECRET_FILE} (0600), and that the SAME value is
# registered with the gateway (client_id ${OIDC_CLIENT_ID}). Returns 0 on
# success. Secrets NEVER on argv / never echoed.
# NOTE on the IMAP HMAC key: it is OWNED by the auth gateway (steps/60 generates
# ${DATA_DIR}/auth-gw/mail-imap-secret.key and is its ONLY reader — it derives each
# user's IMAP password). This step does NOT generate or read it; it only registers
# the snappymail OIDC client so the gateway returns the derived password over the
# secret-gated /token exchange. So both halves agree on ONE key with no duplication.
_provision_oidc_secret() {
  local sm_oidc_env="${SECRETS_HOST}/snappymail-oidc.env"
  local gw_data="${DATA_DIR}/auth-gw"
  local gw_clients_env="${gw_data}/oidc-clients.env"

  # 1. Mint the snappymail OIDC client secret ONCE (alnum-only so it embeds safely
  #    in the gateway's `id=secret` registration); reuse on every re-run.
  if [ ! -s "${sm_oidc_env}" ]; then
    local _sec
    _sec="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)"
    ( umask 077; printf 'SNAPPYMAIL_OIDC_CLIENT_ID=%s\nSNAPPYMAIL_OIDC_CLIENT_SECRET=%s\n' \
        "${OIDC_CLIENT_ID}" "${_sec}" > "${sm_oidc_env}" )
    chmod 600 "${sm_oidc_env}"
    unset _sec
  fi
  # shellcheck disable=SC1090
  . "${sm_oidc_env}"
  [ -n "${SNAPPYMAIL_OIDC_CLIENT_SECRET:-}" ] || { warn "snappymail OIDC client secret empty in ${sm_oidc_env}"; return 1; }

  # 2. Write the secret VALUE into the plugin's 0600 file inside the userland data
  #    dir, over STDIN (never argv), through the bind-mounted data dir.
  printf '%s' "${SNAPPYMAIL_OIDC_CLIENT_SECRET}" \
    | proot-distro login debian --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
        -- bash -lc "umask 077; cat > '${SM_OIDC_SECRET_FILE}' && chmod 600 '${SM_OIDC_SECRET_FILE}'" \
    || { warn "failed to write the plugin OIDC secret file"; return 1; }

  # 3. Register the client (id=secret), its redirect_uri, and mark it a MAIL client
  #    with the gateway — MERGING with any existing registrations so other clients
  #    survive — then bounce the gateway to load it. The secret reaches python via
  #    the environment (SM_SECRET), never argv; the rewritten file is 0600.
  if [ -d "${gw_data}" ]; then
    SM_SECRET="${SNAPPYMAIL_OIDC_CLIENT_SECRET}" python3 - "${gw_clients_env}" "${OIDC_CLIENT_ID}" "${OIDC_REDIRECT_URI}" <<'PY' || { warn "failed to register the snappymail client with the gateway"; return 1; }
import os, re, sys
path, cid, redirect = sys.argv[1], sys.argv[2], sys.argv[3]
sec = os.environ["SM_SECRET"]
vals = {}
try:
    for line in open(path):
        line = line.strip()
        m = re.match(r'(?:export\s+)?([A-Z0-9_]+)=(.*)$', line)
        if m:
            v = m.group(2)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            vals[m.group(1)] = v
except FileNotFoundError:
    pass
def add_csv(key, item):
    items = [x for x in vals.get(key, "").split(",") if x]
    if item not in items:
        items.append(item)
    vals[key] = ",".join(items)
def add_pair(key, cid, val):                       # ; -separated id=val pairs
    pairs = [p for p in re.split(r'[;,]', vals.get(key, "")) if p.strip()]
    pairs = [p for p in pairs if p.split("=", 1)[0].strip() != cid]
    pairs.append(cid + "=" + val)
    vals[key] = ";".join(pairs)
add_pair("AUTHGW_OIDC_EXTRA_CLIENTS", cid, sec)
add_csv("AUTHGW_OIDC_REDIRECT_URIS", redirect)
add_csv("AUTHGW_OIDC_MAIL_CLIENTS", cid)
order = ["AUTHGW_OIDC_EXTRA_CLIENTS", "AUTHGW_OIDC_REDIRECT_URIS", "AUTHGW_OIDC_MAIL_CLIENTS"]
keys = order + [k for k in vals if k not in order]
um = os.umask(0o077)
try:
    with open(path, "w") as f:
        f.write("# OIDC client registrations for matrix-auth-gw (0600). Managed in part\n")
        f.write("# by steps/86-install-webmail.sh; client secrets live here, never on argv.\n")
        for k in keys:
            if vals.get(k, "") != "":
                f.write("export %s='%s'\n" % (k, vals[k]))
finally:
    os.umask(um)
os.chmod(path, 0o600)
print("registered OIDC client %s (+redirect_uri, +mail-client) in %s" % (cid, path))
PY
    chmod 600 "${gw_clients_env}" 2>/dev/null || true
    say "restarting the auth gateway to load the snappymail OIDC client"
    bash "${POCKET_ROOT}/scripts/ops/restart.sh" auth-gw >/dev/null 2>&1 \
      || warn "could not auto-restart the auth gateway — restart it: scripts/ops/restart.sh auth-gw"
  else
    warn "auth-gw data dir ${gw_data} absent (ENABLE_AUTH_GATEWAY + steps/60 not run?) — the SSO plugin will fail until the gateway holds client ${OIDC_CLIENT_ID}"
    return 1
  fi
  return 0
}

# _enable_plugin_fail_closed — enable plugin support + add login-matrix-oidc to
# enabled_list in application.ini, AND allow the OAuth-callback navigation in the
# Sec-Fetch policy, fail-closed. Ported shape is the 59v INSERT-missing-lines +
# post-verify hardening (a freshly-bootstrapped ini that LACKS those keys must
# not silently leave SSO OFF). Returns 0 only if the file ends up correct.
_enable_plugin_fail_closed() {
  local appini="${SM_DDEF}/configs/application.ini"
  # Section-aware application.ini patcher (run IN-PROOT with the data dir bound, so
  # it edits the live file on the large volume). It sets [plugins] enable=On, adds
  # login-matrix-oidc to enabled_list (preserving existing entries), and allows the
  # OAuth-callback navigation in [security] secfetch_allow (the gateway's redirect
  # back to ?MatrixOIDC&code=... is a top-level document navigation the default
  # same-origin Sec-Fetch policy 403s). It INSERTS any missing line, appends the
  # section if absent, and exits NONZERO (fail-closed) if it cannot — so a freshly
  # bootstrapped ini can never silently ship with SSO OFF.
  proot-distro login debian --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
    -- python3 - "${appini}" 'mode=navigate,dest=document' <<'PY' || { warn "application.ini: could not enable login-matrix-oidc (fail-closed)"; return 1; }
import sys, re
p, secfetch = sys.argv[1], sys.argv[2]
lines = open(p).read().splitlines()
have = {'pe': False, 'pl': False, 'sf': False}   # plugins.enable, plugins.enabled_list, security.secfetch_allow
def flush(sec, out):
    if sec == 'plugins':
        if not have['pe']: out.append('enable = On'); have['pe'] = True
        if not have['pl']: out.append('enabled_list = "login-matrix-oidc"'); have['pl'] = True
    elif sec == 'security':
        if not have['sf']: out.append('secfetch_allow = "%s"' % secfetch); have['sf'] = True
out, sec = [], None
for line in lines:
    m = re.match(r'\s*\[([^\]]+)\]', line)
    if m:
        flush(sec, out); sec = m.group(1); out.append(line); continue
    if sec == 'plugins' and re.match(r'\s*enable\s*=', line):
        line = 'enable = On'; have['pe'] = True
    elif sec == 'plugins' and re.match(r'\s*enabled_list\s*=', line):
        mm = re.search(r'=\s*"?([^"]*)"?\s*$', line)
        items = [x.strip() for x in (mm.group(1) if mm else '').split(',') if x.strip()]
        if 'login-matrix-oidc' not in items: items.append('login-matrix-oidc')
        line = 'enabled_list = "%s"' % ','.join(items); have['pl'] = True
    elif sec == 'security' and re.match(r'\s*secfetch_allow\s*=', line):
        line = 'secfetch_allow = "%s"' % secfetch; have['sf'] = True
    out.append(line)
flush(sec, out)
if not (have['pe'] and have['pl']):
    out.append('[plugins]')
    if not have['pe']: out.append('enable = On'); have['pe'] = True
    if not have['pl']: out.append('enabled_list = "login-matrix-oidc"'); have['pl'] = True
if not have['sf']:
    out.append('[security]'); out.append('secfetch_allow = "%s"' % secfetch); have['sf'] = True
open(p, 'w').write('\n'.join(out) + '\n')
sys.exit(0 if (have['pe'] and have['pl'] and have['sf']) else 1)
PY
  # POST-VERIFY (fail-closed): never claim SSO is on when enabled_list lacks it.
  proot-distro login debian --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
    -- bash -lc "grep -qE '^[[:space:]]*enabled_list[[:space:]]*=.*login-matrix-oidc' '${appini}'" \
    || { warn "verify FAILED: login-matrix-oidc absent from enabled_list after edit"; return 1; }
  ok "verified: login-matrix-oidc present in enabled_list (SSO front door enabled)"
  return 0
}

# _enable_admin_panel — enable SnappyMail's NATIVE admin panel host-locked to
# ${SM_ADMIN_HOST} with a generated secret URL key + a strong admin password
# hashed with PHP password_hash(PASSWORD_DEFAULT). Secrets persisted 0600 under
# ${SECRETS_HOST}; the plaintext is shown to the operator to copy + rotate, never
# echoed to a shared log. Returns 0 on success.
_enable_admin_panel() {
  local appini="${SM_DDEF}/configs/application.ini"
  local admin_env="${SECRETS_HOST}/snappymail-admin.env"
  local admin_login="${ADMIN_USER:-admin}"
  # 1. Load any persisted secrets; mint the URL key + a strong password if absent.
  #    Both are alnum-only so they embed safely in the php/ini below; persisted 0600
  #    and REUSED on re-run (re-hashing the same plaintext still verifies).
  # shellcheck disable=SC1090
  [ -f "${admin_env}" ] && . "${admin_env}"
  [ -n "${SNAPPYMAIL_ADMIN_KEY:-}" ]      || SNAPPYMAIL_ADMIN_KEY="$(openssl rand -hex 16)"
  [ -n "${SNAPPYMAIL_ADMIN_PASSWORD:-}" ] || SNAPPYMAIL_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-28)"
  [ -n "${SM_PHP_BIN}" ] || { warn "no php CLI in the userland — cannot hash the admin password"; return 1; }
  # 2. Hash the password INSIDE the userland with PASSWORD_DEFAULT (bcrypt/argon2).
  #    The plaintext is fed over STDIN (never on argv -> never in /proc/<pid>/cmdline);
  #    php reads it with stream_get_contents(STDIN) and strips the trailing newline.
  #    Only the HASH (never the plaintext) is written to application.ini. Validate
  #    the prefix. (proot-distro login forwards stdin — the same stdin-fed approach
  #    syncthing uses for its GUI credential at install time.)
  local admin_hash
  admin_hash="$(printf '%s' "${SNAPPYMAIL_ADMIN_PASSWORD}" | in_debian "${SM_PHP_BIN} -r 'echo password_hash(rtrim(stream_get_contents(STDIN), \"\\r\\n\"), PASSWORD_DEFAULT);'" 2>/dev/null | tr -d '\r')"
  case "${admin_hash}" in
    '$2y$'*|'$2a$'*|'$argon2'*) : ;;
    *) warn "password_hash produced an unexpected value — admin panel NOT enabled"; return 1 ;;
  esac
  # 3. Section-aware application.ini edit (in-proot, data dir bound). The hash is a
  #    single bash-var argv to python, so its '$' is NOT re-expanded by the shell.
  proot-distro login debian --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
    -- python3 - "${appini}" "${admin_login}" "${SM_ADMIN_HOST}" "${SNAPPYMAIL_ADMIN_KEY}" "${admin_hash}" <<'PY' || { warn "application.ini admin edit failed"; return 1; }
import sys, re
p, login, host, key, pwhash = sys.argv[1:6]
lines = open(p).read().splitlines(); sec = None; out = []
for line in lines:
    m = re.match(r'\s*\[([^\]]+)\]', line)
    if m: sec = m.group(1)
    if   sec == 'security'    and re.match(r'\s*allow_admin_panel\s*=', line): line = 'allow_admin_panel = On'
    elif sec == 'security'    and re.match(r'\s*admin_login\s*=', line):       line = 'admin_login = "%s"' % login
    elif sec == 'security'    and re.match(r'\s*admin_password\s*=', line):    line = 'admin_password = "%s"' % pwhash
    elif sec == 'admin_panel' and re.match(r'\s*host\s*=', line):             line = 'host = "%s"' % host
    elif sec == 'admin_panel' and re.match(r'\s*key\s*=', line):              line = 'key = "%s"' % key
    out.append(line)
open(p, 'w').write('\n'.join(out) + '\n')
PY
  # 4. Persist secrets (0600); never echo the key/password to the console.
  ( umask 077; cat > "${admin_env}" <<EOF
# SnappyMail native admin panel (host-locked to ${SM_ADMIN_HOST}). KEEP SECRET.
# Panel at https://${SM_ADMIN_HOST}/ (host-locked; put it behind Cloudflare Access).
SNAPPYMAIL_ADMIN_URL=https://${SM_ADMIN_HOST}/
SNAPPYMAIL_ADMIN_LOGIN=${admin_login}
SNAPPYMAIL_ADMIN_KEY=${SNAPPYMAIL_ADMIN_KEY}
SNAPPYMAIL_ADMIN_PASSWORD=${SNAPPYMAIL_ADMIN_PASSWORD}
EOF
  )
  chmod 600 "${admin_env}"
  say "admin-panel credentials saved to ${admin_env} (0600) — copy them, then rotate after first login"
  return 0
}

# ── Preflight: userland + assets ─────────────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — run scripts/install.sh first"
for f in include.php php-fpm.conf.tmpl mail-domain.json.tmpl webmail.caddy.tmpl webmail-admin.caddy.tmpl; do
  [ -f "${ASSET_DIR}/${f}" ] || die "missing asset ${ASSET_DIR}/${f}"
done
mkdir -p "${SM_DATA_HOST}"
chmod 700 "${SM_DATA_HOST}" 2>/dev/null || true
mkdir -p "${SECRETS_HOST}"
chmod 700 "${SECRETS_HOST}" 2>/dev/null || true

# ── 1. php-fpm + the PHP extensions SnappyMail needs (idempotent) ────────────
# SnappyMail needs: curl, mbstring, xml, intl, zip, sqlite3, gd. Unversioned
# package names let apt pick whatever PHP the userland's Debian ships (portable
# across Debian releases). The validate step fails closed if php-fpm is absent.
run_once webmail-apt -- in_debian '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    php-fpm php-cli php-curl php-mbstring php-xml php-intl php-zip php-sqlite3 php-gd \
    curl ca-certificates
' || die "could not install php-fpm + SnappyMail PHP extensions inside the userland"

# Resolve the php-fpm binary the userland actually installed (package name is
# unversioned; the binary on PATH is php-fpmX.Y). Fail closed if absent.
SM_FPM_BIN="$(in_debian 'command -v php-fpm8.4 || command -v php-fpm8.3 || command -v php-fpm8.2 || command -v php-fpm8.1 || ls /usr/sbin/php-fpm* 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')"
[ -n "${SM_FPM_BIN}" ] || die "no php-fpm binary found in the userland after apt install — check 'proot-distro login debian -- ls /usr/sbin/php-fpm*'"
ok "php-fpm binary: ${SM_FPM_BIN}"
# The matching php CLI (for plugin lint + the application.ini patcher's password hash).
SM_PHP_BIN="$(in_debian 'command -v php8.4 || command -v php8.3 || command -v php8.2 || command -v php8.1 || command -v php' 2>/dev/null | tr -d '\r')"

# ── 2. Fetch the pinned source + extract (preserving the data dir on upgrade) ─
if in_debian "[ -f '${SM_WEBROOT}/snappymail/v/${SM_VER}/include.php' ]"; then
  ok "SnappyMail ${SM_VER} already extracted at ${SM_WEBROOT}"
else
  say "downloading + sha256-verifying + extracting SnappyMail ${SM_VER}"
  # sha256 verified fail-closed INSIDE the userland (sha256sum -c), so a
  # corrupt/tampered tarball aborts rather than running unknown code.
  in_debian "
    set -e
    mkdir -p '${SM_WEBROOT}'
    cd /opt
    curl -fsSL --retry 3 -o sm.tar.gz '${SM_URL}'
    echo '${SM_SHA256}  sm.tar.gz' | sha256sum -c -
    tar -xzf sm.tar.gz -C '${SM_WEBROOT}'
    rm -f sm.tar.gz
  " 2>&1 | grep -v 'proot warning' \
    || die "SnappyMail download/verify/extract failed (bad URL, or sha256 mismatch vs ${SM_SHA256})"
  ok "SnappyMail ${SM_VER} extracted to ${SM_WEBROOT}"
fi
in_debian "[ -f '${SM_WEBROOT}/index.php' ]" \
  || die "SnappyMail tree incomplete at ${SM_WEBROOT} (need index.php)"

# ── 3. include.php (data dir outside webroot) + the php-fpm pool ─────────────
say "placing include.php (data dir outside webroot) + the php-fpm pool"
proot-distro login debian -- bash -lc "umask 022; cat > '${SM_WEBROOT}/include.php'" < "${ASSET_DIR}/include.php" \
  || die "failed to write ${SM_WEBROOT}/include.php"
# php-fpm pool: substitute the loopback bind + port into the template.
sed -e "s|__CADDY_BIND__|${CADDY_BIND}|g" \
    -e "s|__FPM_PORT__|${SM_FPM_PORT}|g" \
    "${ASSET_DIR}/php-fpm.conf.tmpl" \
  | proot-distro login debian -- bash -lc "umask 077; cat > '${SM_FPM_CONF}'" \
  || die "failed to write ${SM_FPM_CONF}"
# Data dir backing on the large volume (bind-mounted into the userland at
# supervise/init time). The in-userland mountpoint must also exist.
in_debian "mkdir -p '${SM_DATA_USERLAND}' && chmod 700 '${SM_DATA_USERLAND}'" \
  || die "failed to create ${SM_DATA_USERLAND} in the userland"
ok "wrote include.php + ${SM_FPM_CONF}"

# ── 4. Caddy vhost (self-contained site block, imported by the core Caddyfile) ─
say "writing the Caddy vhost → /etc/caddy/apps/webmail.caddy"
sed -e "s|__HOST__|${SM_HOST}|g" \
    -e "s|__CADDY_BIND__|${CADDY_BIND}|g" \
    -e "s|__CADDY_PORT__|${CADDY_PORT}|g" \
    -e "s|__FPM_PORT__|${SM_FPM_PORT}|g" \
    -e "s|__AUTHGW_PORT__|${AUTHGW_PORT:-9095}|g" \
    -e "s|\${DOMAIN}|${DOMAIN}|g" \
    "${ASSET_DIR}/webmail.caddy.tmpl" \
  | proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/webmail.caddy' \
  || die "failed to write /etc/caddy/apps/webmail.caddy"
ok "wrote /etc/caddy/apps/webmail.caddy"

# Validate the FULL Caddyfile inside the userland (fail closed). We do NOT
# restart Caddy here — print the restart hint instead.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/webmail.caddy)"
ok "Caddyfile still valid with the webmail vhost added"

# ── 5. Write the in-userland php-fpm launcher + supervise ────────────────────
# Kept as a file inside the userland to avoid nested-quoting through
# supervise→bash -c→proot-distro→bash -c. php-fpm runs in the FOREGROUND (-F)
# under the supervisor; -R lets the pool run as root (proot is single-user root).
# The launch argv carries 'snappymail/php-fpm.conf', the identity marker the
# supervisor (and the admin panel health check) match on.
say "writing ${SM_WEBROOT}/run-fpm.sh launcher"
proot-distro login debian -- bash -lc "umask 077; cat > '${SM_WEBROOT}/run-fpm.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by steps/86-install-webmail.sh.
# Serves SnappyMail on ${CADDY_BIND}:${SM_FPM_PORT}; Caddy fronts the public TLS edge.
exec ${SM_FPM_BIN} -R -F -y '${SM_FPM_CONF}'
LAUNCH
in_debian "chmod +x '${SM_WEBROOT}/run-fpm.sh'" || die "failed to make ${SM_WEBROOT}/run-fpm.sh executable"

# Supervise php-fpm with the large-volume data dir bind-mounted in (so the
# SnappyMail data folder lands on ${DATA_DIR}).
supervise snappymail-fpm -- \
  proot-distro login debian \
  --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
  -- bash "${SM_WEBROOT}/run-fpm.sh"

# Wait for the FastCGI port to accept (probe from inside the userland).
say "waiting for php-fpm to listen on 127.0.0.1:${SM_FPM_PORT}"
fpm_up=0
for _ in $(seq 1 20); do
  if in_debian "python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex((\"127.0.0.1\",${SM_FPM_PORT}))==0 else 1)'" >/dev/null 2>&1; then
    fpm_up=1; break
  fi
  sleep 1
done
[ "${fpm_up}" -eq 1 ] && ok "php-fpm listening on 127.0.0.1:${SM_FPM_PORT}" \
  || warn "php-fpm not listening yet on ${CADDY_BIND}:${SM_FPM_PORT} — check ${POCKET_LOG_DIR}/snappymail-fpm.log"

# ── 6. Bootstrap the data dir (first request creates _data_/_default_) ────────
# SnappyMail creates its data tree (incl. configs/application.ini) on the first
# HTTP request. We drive it through the running Caddy edge over loopback with the
# webmail Host header, retrying until application.ini appears.
if in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]"; then
  ok "SnappyMail data dir already bootstrapped"
else
  say "bootstrapping the SnappyMail data dir (loopback request through Caddy)"
  for _ in $(seq 1 10); do
    in_debian "curl -s -o /dev/null -m 15 -H 'Host: ${SM_HOST}' http://${CADDY_BIND}:${CADDY_PORT}/" >/dev/null 2>&1 || true
    in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]" && break
    sleep 2
  done
  in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]" \
    || warn "data dir did not bootstrap — verify caddy + ${POCKET_LOG_DIR}/snappymail-fpm.log, then re-run; webmail config steps below were skipped"
fi

# ── 7. Pin the domain to mail.${DOMAIN} (loopback IMAP/SMTP) + drop public providers ─
if in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]"; then
  say "configuring domain ${MAIL_HOST} -> loopback IMAP :${IMAP_PORT} / SMTP :${SMTP_PORT} + dropping public providers"
  # the domain JSON (substitute the Maddy loopback ports).
  sed -e "s|__IMAP_PORT__|${IMAP_PORT}|g" \
      -e "s|__SMTP_PORT__|${SMTP_PORT}|g" \
      "${ASSET_DIR}/mail-domain.json.tmpl" \
    | proot-distro login debian \
        --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
        -- bash -lc "umask 077; mkdir -p '${SM_DDEF}/domains'; cat > '${SM_DDEF}/domains/${MAIL_HOST}.json'" \
    || die "failed to write the ${MAIL_HOST} domain config"
  # lock webmail to our domain only (drop the bundled public providers).
  in_debian_data "cd '${SM_DDEF}/domains' 2>/dev/null && rm -f gmail.com.json hotmail.com.json localhost.json default.json outlook.com.json yahoo.com.json 2>/dev/null; true"
  # default_domain + disable the admin panel by default (re-enabled below only if
  # ENABLE_WEBMAIL_ADMIN=true). Section-unaware single-line replacements mirror the
  # reference; the keys are unique in a bootstrapped application.ini.
  in_debian_data "python3 - <<'PY'
import re
p='${SM_DDEF}/configs/application.ini'
s=open(p).read()
for a,b in [(r'default_domain = \"[^\"]*\"','default_domain = \"${MAIL_HOST}\"'),
            (r'allow_admin_panel = On','allow_admin_panel = Off')]:
    s=re.sub(a,b,s,count=1)
open(p,'w').write(s)
print('application.ini: default_domain + admin panel set')
PY" 2>&1 | grep -v 'proot warning' || warn "application.ini domain patch reported an issue — inspect ${SM_DDEF}/configs/application.ini"
  in_debian_data "rm -rf '${SM_DDEF}/cache/'* 2>/dev/null; true"
  ok "domain pinned to ${MAIL_HOST}; public providers removed"
fi

# ── 8. (optional) Matrix-SSO via the login-matrix-oidc plugin ────────────────
# Only wired when the auth gateway is enabled. Deploys the plugin (env-templated),
# writes the client secret to a 0600 file the plugin reads, and ENABLES it in
# application.ini fail-closed. The secret-derivation + enable-hardening are the
# security-critical helpers _provision_oidc_secret + _enable_plugin_fail_closed.
if [ "${ENABLE_AUTH_GATEWAY:-false}" = "true" ] && in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]"; then
  say "deploying the login-matrix-oidc SSO plugin"
  [ -f "${PLUGIN_SRC}/index.php" ] || die "plugin source missing at ${PLUGIN_SRC}/index.php"

  # OIDC endpoints, derived from .env. authorize is PUBLIC (reached via the
  # gateway's /authgw/* edge on a gated app host); token is LOOPBACK. The public
  # authorize host follows the gateway's edge (any gated app vhost proxies
  # /authgw/* to the gateway); default to the webmail host's own /authgw/* path.
  GW_PORT="${AUTHGW_PORT:-9095}"
  OIDC_AUTHORIZE_URL="${SNAPPYMAIL_OIDC_AUTHORIZE_URL:-https://${SM_HOST}/authgw/oidc/authorize}"
  OIDC_TOKEN_URL="${SNAPPYMAIL_OIDC_TOKEN_URL:-http://127.0.0.1:${GW_PORT}/authgw/oidc/token}"
  OIDC_REDIRECT_URI="${SNAPPYMAIL_OIDC_REDIRECT_URI:-https://${SM_HOST}/?MatrixOIDC}"
  OIDC_CLIENT_ID="${SNAPPYMAIL_OIDC_CLIENT_ID:-snappymail}"
  WELCOME_FROM="${SNAPPYMAIL_WELCOME_FROM:-welcome@${MAIL_HOST}}"
  CHAT_URL="https://chat.${DOMAIN}"
  WEBMAIL_URL="https://${SM_HOST}"
  BRAND="${SNAPPYMAIL_BRAND:-${DOMAIN}}"

  PLUG_DST="${SM_DDEF}/plugins/login-matrix-oidc"
  in_debian_data "mkdir -p '${PLUG_DST}'" || die "could not create ${PLUG_DST} in the userland"

  # Deploy index.php with the __TOKENS__ substituted (NO secrets — the client
  # secret is read at runtime from SM_OIDC_SECRET_FILE).
  sed -e "s|__OIDC_AUTHORIZE_URL__|${OIDC_AUTHORIZE_URL}|g" \
      -e "s|__OIDC_TOKEN_URL__|${OIDC_TOKEN_URL}|g" \
      -e "s|__OIDC_REDIRECT_URI__|${OIDC_REDIRECT_URI}|g" \
      -e "s|__OIDC_CLIENT_ID__|${OIDC_CLIENT_ID}|g" \
      -e "s|__MADDY_DIR__|${MADDY_DIR}|g" \
      -e "s|__MADDY_CONFIG__|${MADDY_CONFIG}|g" \
      -e "s|__WELCOME_FROM__|${WELCOME_FROM}|g" \
      -e "s|__MAIL_HOST__|${MAIL_HOST}|g" \
      "${PLUGIN_SRC}/index.php" \
    | proot-distro login debian \
        --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
        -- bash -lc "umask 022; cat > '${PLUG_DST}/index.php'" \
    || die "failed to deploy the plugin index.php"
  # matrix-oidc.js verbatim; welcome.html with brand/links substituted.
  proot-distro login debian \
      --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
      -- bash -lc "umask 022; cat > '${PLUG_DST}/matrix-oidc.js'" < "${PLUGIN_SRC}/matrix-oidc.js" \
    || die "failed to deploy matrix-oidc.js"
  if [ -f "${PLUGIN_SRC}/welcome.html" ]; then
    sed -e "s|{{BRAND}}|${BRAND}|g" \
        -e "s|__MAIL_HOST__|${MAIL_HOST}|g" \
        -e "s|__CHAT_URL__|${CHAT_URL}|g" \
        -e "s|__WEBMAIL_URL__|${WEBMAIL_URL}|g" \
        "${PLUGIN_SRC}/welcome.html" \
      | proot-distro login debian \
          --bind "${SM_DATA_HOST}:${SM_DATA_USERLAND}" \
          -- bash -lc "umask 022; cat > '${PLUG_DST}/welcome.html'" \
      || warn "failed to deploy welcome.html — new-member welcome email will be skipped"
  fi
  # Lint the deployed plugin (fail-closed: never enable code that does not parse).
  if [ -n "${SM_PHP_BIN}" ]; then
    in_debian_data "${SM_PHP_BIN} -l '${PLUG_DST}/index.php' >/dev/null 2>&1" \
      || die "plugin index.php FAILED php -l — not enabling (fix ${PLUGIN_SRC}/index.php)"
    ok "plugin index.php lint clean"
  else
    warn "no php CLI in the userland — skipping plugin lint"
  fi

  # ── security-critical: provision + enable, fail-closed ─────────────────────
  # Provision the OIDC client secret (the SAME value the gateway holds for
  # client_id ${OIDC_CLIENT_ID}) into a 0600 file the plugin reads, then ENABLE
  # the plugin in application.ini fail-closed (INSERT-missing-lines + post-verify).
  # Both must fail closed: a silent disable would ship webmail with the SSO front
  # door OFF; a leaked/echoed secret would be a credential compromise.
  _provision_oidc_secret \
    && _enable_plugin_fail_closed \
    || die "OIDC plugin enable failed (fail-closed) — webmail would silently fall back to non-SSO login; inspect ${SM_DDEF}/configs/application.ini"

  # clear cache so the plugin loads; bounce php-fpm.
  in_debian_data "rm -rf '${SM_DDEF}/cache/'* 2>/dev/null; true"
  say "restarting php-fpm to load the plugin"
  bash "${POCKET_ROOT}/scripts/ops/restart.sh" snappymail-fpm >/dev/null 2>&1 || true
  ok "login-matrix-oidc plugin deployed + enabled"
else
  say "auth gateway off (ENABLE_AUTH_GATEWAY != true) — SnappyMail uses its native IMAP login (no SSO plugin)"
fi

# ── 9. (optional) host-locked native admin panel ─────────────────────────────
# Off by default. When ENABLE_WEBMAIL_ADMIN=true, enable SnappyMail's own admin
# panel HOST-LOCKED to webmail-admin.${DOMAIN} (a SEPARATE host from the user
# webmail) behind Cloudflare Access. The admin login + secret-key + password
# hashing are handled by the security-critical _enable_admin_panel helper.
if [ "${ENABLE_WEBMAIL_ADMIN:-false}" = "true" ] && in_debian_data "[ -f '${SM_DDEF}/configs/application.ini' ]"; then
  say "enabling the host-locked native admin panel on ${SM_ADMIN_HOST}"
  # drop the admin-host vhost (Cf-Access-gated) + validate.
  sed -e "s|__ADMIN_HOST__|${SM_ADMIN_HOST}|g" \
      -e "s|__CADDY_BIND__|${CADDY_BIND}|g" \
      -e "s|__CADDY_PORT__|${CADDY_PORT}|g" \
      -e "s|__FPM_PORT__|${SM_FPM_PORT}|g" \
      -e "s|\${DOMAIN}|${DOMAIN}|g" \
      "${ASSET_DIR}/webmail-admin.caddy.tmpl" \
    | proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/webmail-admin.caddy' \
    || die "failed to write /etc/caddy/apps/webmail-admin.caddy"
  in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
    || die "caddy validate FAILED after adding the webmail-admin vhost (fix /etc/caddy/apps/webmail-admin.caddy)"
  _enable_admin_panel || die "admin panel enable failed — inspect ${SM_DDEF}/configs/application.ini"
  in_debian_data "rm -rf '${SM_DDEF}/cache/'* 2>/dev/null; true"
  bash "${POCKET_ROOT}/scripts/ops/restart.sh" snappymail-fpm >/dev/null 2>&1 || true
  ok "native admin panel enabled (host-locked to ${SM_ADMIN_HOST})"
fi

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "SnappyMail webmail installed + supervised (php-fpm ${CADDY_BIND}:${SM_FPM_PORT}; data on ${SM_DATA_HOST})"
say "Mailbox domain: ${MAIL_HOST} (loopback IMAP :${IMAP_PORT} / SMTP :${SMTP_PORT})."
echo
say "Manual Cloudflare steps (in the Cloudflare dashboard — NOT done by this script):"
say "  1. In the Tunnel config, add a Public Hostname:"
say "       ${SM_HOST}  ->  http://localhost:${CADDY_PORT}  (the local Caddy edge, plain HTTP)"
say "  2. (optional) ${SM_ADMIN_HOST} -> http://localhost:${CADDY_PORT}, behind a Cloudflare Access policy."
say "  If the core stack is already running, pick up the new vhost with:"
say "       bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
say "  (brief ingress outage while cloudflared cycles)."

# Generalized from a working deployment; review before running.
