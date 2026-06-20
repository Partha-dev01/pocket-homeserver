#!/usr/bin/env bash
#
# steps/85-install-email.sh — install + supervise the OPTIONAL self-hosted email
# backend: the Maddy mail engine (IN the Debian userland) plus the native R2 drain
# loop that pulls inbound mail and injects it into Maddy.
#
# This is an ADVANCED add-on with real external prerequisites you provision on your
# OWN Cloudflare + Resend accounts (see docs/EMAIL.md):
#   * Cloudflare Email Routing for your mail domain, pointed at the Email Worker in
#     scripts/email/worker/ (you deploy it with wrangler),
#   * an R2 bucket the Worker writes inbound mail to (+ a bucket-scoped R2 token),
#   * a Resend account/API key for OUTBOUND (the Maddy smarthost).
#
# It is a core step that SELF-GATES on ENABLE_EMAIL (install.sh runs it
# unconditionally; it no-ops unless you opt in), so a default install never touches
# it. Default OFF.
#
# What it does (idempotent — safe to re-run):
#   1. installs the pinned Maddy release binary into /opt/maddy inside the userland
#      (fetch_verified, fail-closed sha256),
#   2. renders scripts/email/maddy.conf.tmpl -> /opt/maddy/maddy.conf (hostname,
#      mail domain, loopback ports from .env),
#   3. generates + persists, on the large volume (chmod 600, reused on re-run):
#        - the inject SMTP-AUTH credential (drain <-> Maddy loopback),
#        - the catch-all inbox mailbox password,
#        - the admin mailbox password,
#      and writes the R2 + Resend secrets the operator supplies into 0600 files,
#   4. provisions the inject credential + the inbox + admin mailboxes in Maddy
#      (idempotent; self-heals after a rootfs wipe),
#   5. writes an in-userland launcher that wires Maddy's config + sources the relay
#      secret (RESEND_API_KEY reaches Maddy via {env:...}, NEVER on argv), and a
#      native launcher for the drain that exports R2 + inject creds into the child
#      env (never argv),
#   6. supervises maddy (in-proot) + mail-drain (native) and health-checks the IMAP
#      port.
#
# NO Caddy vhost is written here — a webmail UI (a separate optional component) is
# what adds a public vhost. Maddy is reachable only on loopback (IMAP/inject/
# submission). Outbound goes to Resend; inbound arrives via the drain.
#
# MIRRORS: steps/60-install-auth-gw.sh (in-proot install + secret gen + supervise),
# apps/freshrss.sh (in-userland service style), ops/backup-db.sh (proot conventions).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when explicitly enabled ──────────────────────────────
if [ "${ENABLE_EMAIL:-false}" != "true" ]; then
  ok "email backend disabled (ENABLE_EMAIL != true) — skipping (this is the default)"
  exit 0
fi

require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Config ───────────────────────────────────────────────────────────────────
MAIL_DOMAIN="${MAIL_DOMAIN:-mail.${DOMAIN}}"          # the mail domain (CF Email Routing target)
MAIL_HOSTNAME="${MAIL_HOSTNAME:-mx.${MAIL_DOMAIN}}"   # Maddy EHLO/greeting hostname
MAIL_IMAP_PORT="${MAIL_IMAP_PORT:-9143}"              # loopback IMAP (a webmail client reads this)
MAIL_INJECT_PORT="${MAIL_INJECT_PORT:-9125}"          # loopback inject (drain delivers here, AUTH)
MAIL_SUBMISSION_PORT="${MAIL_SUBMISSION_PORT:-9587}"  # loopback submission -> smarthost (outbound)
MAIL_POLL="${MAIL_POLL:-180}"                         # drain poll interval (seconds)
MAIL_ADMIN_LOCALPART="${MAIL_ADMIN_LOCALPART:-admin}" # role/admin mail funnels to <this>@MAIL_DOMAIN

MADDY_DIR="/opt/maddy"                                # install dir INSIDE the userland
MADDY_BIN="${MADDY_DIR}/maddy"
MADDY_CONF="${MADDY_DIR}/maddy.conf"
MADDY_STATE_HOST="${DATA_DIR}/mail/maddy-state"       # imapsql + credentials DBs on the large volume
MADDY_STATE_USERLAND="${MADDY_DIR}/state"             # bind target inside the userland
CONF_TMPL="${POCKET_ROOT}/scripts/email/maddy.conf.tmpl"
DRAIN_SRC="${POCKET_ROOT}/scripts/email/mail-drain.py"

# Secrets / config on the large volume (chmod 600). The operator supplies R2 +
# Resend; the installer generates the inject + mailbox creds + the HMAC key.
SECRETS_DIR="${DATA_DIR}/secrets"
R2_ENV="${SECRETS_DIR}/mail-r2.env"            # operator: R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET
RELAY_ENV="${SECRETS_DIR}/mail-relay.env"      # operator: RESEND_API_KEY (Maddy reads via {env:...})
INJECT_ENV="${SECRETS_DIR}/mail-inject.env"    # generated: INJECT_USER/INJECT_PASS + INBOX_USER/INBOX_PASS
ADMIN_ENV="${SECRETS_DIR}/mail-admin.env"      # generated: ADMIN_USER/ADMIN_PASS (admin mailbox)
# NOTE: the per-user IMAP-password HMAC key (for Matrix-SSO webmail) is owned by the
# auth gateway (steps/60 generates it under ${DATA_DIR}/auth-gw and is its only
# reader); it is NOT generated here. Native IMAP login uses the inbox/admin
# passwords above; SSO webmail uses the gateway-derived per-user password.

# ── Pinned Maddy release ──────────────────────────────────────────────────────
# Pin an EXACT upstream version (env-overridable) so an upgrade is deliberate. The
# reference deployment ran Maddy 0.9.5 aarch64 (musl) in proot. The release archive
# is published at the foxcpp/maddy GitHub releases. NOTE: the reference installed
# the binary by hand and did NOT record a sha256, so the pin below is a clearly
# marked placeholder — DO NOT trust it as-is.
#
# TODO(human:pin): set MADDY_SHA256 to the real sha256 of the archive you download
# for your CPU arch (verify against the upstream checksums / release page). For an
# arm64 phone that is the `aarch64` asset, e.g.:
#   maddy-${MADDY_VERSION}-aarch64-linux-musl.tar.zst
#   curl -fsSL "$MADDY_URL" | sha256sum
# fetch_verified is fail-closed: with the placeholder hash the download is rejected
# and the install aborts rather than running an unverified binary.
MADDY_VERSION="${MADDY_VERSION:-0.9.5}"
MADDY_ARCH="${MADDY_ARCH:-aarch64}"   # upstream uses 'aarch64' for arm64 phones; set 'amd64' on an x86 PC test box
MADDY_URL="${MADDY_URL:-https://github.com/foxcpp/maddy/releases/download/v${MADDY_VERSION}/maddy-${MADDY_VERSION}-${MADDY_ARCH}-linux-musl.tar.zst}"
MADDY_SHA256="${MADDY_SHA256:-PLACEHOLDER_SET_REAL_SHA256_SEE_TODO_human_pin}"

# ── Preflight: the userland + the source files must exist ────────────────────
[ -f "${CONF_TMPL}" ]  || die "maddy.conf template missing: ${CONF_TMPL}"
[ -f "${DRAIN_SRC}" ]  || die "mail-drain.py missing: ${DRAIN_SRC}"
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — run scripts/install.sh first"

mkdir -p "${SECRETS_DIR}" "${MADDY_STATE_HOST}" "${DATA_DIR}/mail"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# Operator-supplied secrets must exist (we can't generate these).
[ -s "${R2_ENV}" ] || die "missing ${R2_ENV} — create it (R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET from a bucket-scoped R2 token), chmod 600. See docs/EMAIL.md"
[ -s "${RELAY_ENV}" ] || die "missing ${RELAY_ENV} — create it (RESEND_API_KEY from the Resend dashboard; the SMTP user is the literal 'resend'), chmod 600. See docs/EMAIL.md"

# ── 1. Install the pinned Maddy binary into the userland ─────────────────────
# Fetch + verify on the HOST (Termux curl/sha256sum), then copy into the userland.
# fetch_verified is fail-closed; with the placeholder sha it aborts until pinned.
if in_debian "[ -x '${MADDY_BIN}' ]" && in_debian "'${MADDY_BIN}' version 2>/dev/null | grep -q '${MADDY_VERSION}'"; then
  ok "Maddy ${MADDY_VERSION} already installed at ${MADDY_BIN}"
else
  say "downloading + sha256-verifying Maddy ${MADDY_VERSION} (${MADDY_ARCH})"
  STAGE="${DATA_DIR}/mail/.maddy-dl"
  mkdir -p "${STAGE}"
  fetch_verified "${MADDY_URL}" "${STAGE}/maddy.tar.zst" "${MADDY_SHA256}"
  say "installing the Maddy binary into ${MADDY_DIR} (inside the userland)"
  in_debian "mkdir -p '${MADDY_DIR}'" || die "could not create ${MADDY_DIR} in the userland"
  # Extract on the host (zstd) then stream the binary in over stdin so nothing but
  # the verified bytes cross into the userland. The release tar holds a top-level
  # maddy-<ver>-.../ dir with the `maddy` binary inside it.
  ( cd "${STAGE}" && tar --use-compress-program=unzstd -xf maddy.tar.zst ) \
    || die "failed to extract the Maddy archive (need zstd/unzstd on the host)"
  MADDY_EXTRACTED="$(find "${STAGE}" -maxdepth 3 -type f -name maddy -perm -u+x 2>/dev/null | head -1)"
  [ -n "${MADDY_EXTRACTED}" ] || MADDY_EXTRACTED="$(find "${STAGE}" -maxdepth 3 -type f -name maddy 2>/dev/null | head -1)"
  [ -n "${MADDY_EXTRACTED}" ] || die "no 'maddy' binary found in the extracted archive"
  proot-distro login debian -- bash -lc "umask 022; cat > '${MADDY_BIN}' && chmod 755 '${MADDY_BIN}'" < "${MADDY_EXTRACTED}" \
    || die "failed to copy the Maddy binary into the userland"
  rm -rf "${STAGE}"
  in_debian "[ -x '${MADDY_BIN}' ]" || die "Maddy binary not executable at ${MADDY_BIN} after install"
  ok "Maddy ${MADDY_VERSION} installed at ${MADDY_BIN}"
fi

# ── 2. State dir on the large volume (imapsql + credentials DBs) ─────────────
# Maddy's state_dir is /opt/maddy/state (set in the config). We back it with a dir
# on the large volume via a bind mount so the mailbox + creds DBs survive a rootfs
# rebuild. Create both the in-userland mountpoint and the backing dir.
in_debian "mkdir -p '${MADDY_STATE_USERLAND}' '${MADDY_DIR}/run'" || die "failed to create ${MADDY_STATE_USERLAND} in the userland"
mkdir -p "${MADDY_STATE_HOST}"
ok "Maddy state backing dir ready: ${MADDY_STATE_HOST} (bind-mounted at ${MADDY_STATE_USERLAND})"

# ── 3. Render maddy.conf from the template ───────────────────────────────────
# Substitute the __PLACEHOLDER__ tokens with .env-derived values. No secrets are
# rendered — RESEND_API_KEY stays a {env:...} reference resolved at runtime.
say "rendering ${MADDY_CONF} from the template (hostname=${MAIL_HOSTNAME}, domain=${MAIL_DOMAIN})"
rendered="$(
  sed \
    -e "s|__MAIL_HOSTNAME__|${MAIL_HOSTNAME}|g" \
    -e "s|__MAIL_DOMAIN__|${MAIL_DOMAIN}|g" \
    -e "s|__IMAP_PORT__|${MAIL_IMAP_PORT}|g" \
    -e "s|__INJECT_PORT__|${MAIL_INJECT_PORT}|g" \
    -e "s|__SUBMISSION_PORT__|${MAIL_SUBMISSION_PORT}|g" \
    "${CONF_TMPL}"
)"
printf '%s\n' "${rendered}" | proot-distro login debian -- bash -lc "umask 022; cat > '${MADDY_CONF}'" \
  || die "failed to write ${MADDY_CONF} into the userland"
ok "wrote ${MADDY_CONF}"

# ── 4. Generate + persist credentials on the large volume (chmod 600, reused) ─
# All credential material is CSPRNG-generated once, written via `( umask 077; ... )`
# + chmod 600, reused on every re-run (the `-s` guard), and never echoed to
# stdout/logs or placed on argv:
#
#   * INJECT_ENV — the inject SMTP-AUTH credential (INJECT_USER/INJECT_PASS) the
#                  drain uses to authenticate to Maddy's loopback inject endpoint,
#                  plus the catch-all INBOX_USER/INBOX_PASS.
#   * ADMIN_ENV  — the admin mailbox credential (ADMIN_USER/ADMIN_PASS); role mail
#                  (postmaster@/abuse@/dmarc@/...) funnels here via the drain.
#
# The per-user IMAP-password HMAC key (Matrix-SSO webmail only) is the auth
# gateway's (steps/60) — see the NOTE by the secret-path definitions above.
mail_user() { printf '%s@%s' "$1" "${MAIL_DOMAIN}"; }

# --- inject + inbox creds ---
if [ ! -s "${INJECT_ENV}" ]; then
  say "generating inject + inbox mailbox creds -> ${INJECT_ENV} (chmod 600)"
  # CSPRNG passwords, alnum-only (openssl base64 -> drop +/= ) so they are
  # quoting-safe when handed to the Maddy CLI below and source cleanly from the env
  # file. ingest@ is the inject identity (a credential with NO mailbox); inbox@ is
  # the catch-all mailbox a webmail client (or native IMAP login) reads. Generated
  # once and reused on every re-run (the `-s` guard), so the password is stable.
  _injp="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
  _inbp="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
  ( umask 077; cat > "${INJECT_ENV}" <<EOF
INJECT_USER=$(mail_user ingest)
INJECT_PASS=${_injp}
INBOX_USER=$(mail_user inbox)
INBOX_PASS=${_inbp}
EOF
  )
  chmod 600 "${INJECT_ENV}"
  unset _injp _inbp
fi
# shellcheck disable=SC1090
[ -s "${INJECT_ENV}" ] && . "${INJECT_ENV}"

# --- admin mailbox creds ---
if [ ! -s "${ADMIN_ENV}" ]; then
  say "generating admin mailbox creds -> ${ADMIN_ENV} (chmod 600)"
  # The admin mailbox (admin@MAIL_DOMAIN) collects role mail (postmaster@/abuse@/
  # dmarc@/...) routed by the drain. Standalone password (NOT an OIDC-derived one —
  # admin@ has no SSO login); read it from this 0600 file or add admin@ as an extra
  # account in the webmail.
  _admp="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  ( umask 077; printf 'ADMIN_USER=%s\nADMIN_PASS=%s\n' "$(mail_user "${MAIL_ADMIN_LOCALPART}")" "${_admp}" > "${ADMIN_ENV}" )
  chmod 600 "${ADMIN_ENV}"
  unset _admp
fi
# shellcheck disable=SC1090
[ -s "${ADMIN_ENV}" ] && . "${ADMIN_ENV}"

# ── 5. Provision Maddy accounts (idempotent; self-heals after a rootfs wipe) ──
# Create the inject credential + the inbox/admin mailboxes in Maddy's pass_table +
# imapsql. We run BEFORE the server is supervised (so the CLI writes the state DBs
# directly), inside the SAME proot with the state dir bind-mounted so the DBs land
# on the large volume. Idempotent: the `creds list | grep -qxF || create` guard
# makes a re-run (or a self-heal after a rootfs wipe, since the DBs survive on the
# large volume) a no-op.
#
# Credential VALUES come from the 0600 env files sourced above. The passwords are
# alnum-only CSPRNG strings, so passing them to `maddy creds create --password` is
# quoting-safe; this is a conscious, local-only argv exposure on a single-user
# device during one install-time provisioning call (Maddy 0.9.5 has no documented
# password-on-stdin for `creds create`). Subcommand spelling matches recent Maddy
# builds (`maddy creds` / `maddy imap-acct`); verify on-device against your pinned
# build (older builds used a separate `maddyctl`).
[ -n "${INJECT_USER:-}" ] && [ -n "${INJECT_PASS:-}" ] || die "inject creds unset — ${INJECT_ENV} missing/corrupt"
[ -n "${INBOX_USER:-}" ]  && [ -n "${INBOX_PASS:-}" ]  || die "inbox creds unset — ${INJECT_ENV} missing/corrupt"
[ -n "${ADMIN_USER:-}" ]  && [ -n "${ADMIN_PASS:-}" ]  || die "admin creds unset — ${ADMIN_ENV} missing/corrupt"

maddy_provision() {   # maddy_provision <user> <password> <make_mailbox:yes|no>
  local u="$1" p="$2" mbx="$3"
  proot-distro login debian \
    --bind "${MADDY_STATE_HOST}:${MADDY_STATE_USERLAND}" \
    -- bash -lc "
      export MADDY_CONFIG='${MADDY_CONF}'; cd '${MADDY_DIR}' || exit 1
      ./maddy creds list 2>/dev/null | grep -qxF '${u}' || ./maddy creds create --password '${p}' '${u}'
      if [ '${mbx}' = 'yes' ]; then
        ./maddy imap-acct list 2>/dev/null | grep -qxF '${u}' || ./maddy imap-acct create '${u}'
      fi
    " 2>&1 | grep -vE 'proot warning|TLS is disabled' || true
}

say "provisioning Maddy accounts (ingest credential + inbox + admin mailboxes; idempotent)"
maddy_provision "${INJECT_USER}" "${INJECT_PASS}" no    # inject identity: credential only, no mailbox
maddy_provision "${INBOX_USER}"  "${INBOX_PASS}"  yes   # catch-all inbox mailbox
maddy_provision "${ADMIN_USER}"  "${ADMIN_PASS}"  yes   # admin/role mailbox
ok "Maddy accounts provisioned (verify with: proot-distro login debian -- bash -lc 'cd ${MADDY_DIR} && MADDY_CONFIG=${MADDY_CONF} ./maddy imap-acct list')"

# ── 6a. Maddy launcher (in-userland; sources the relay secret) ───────────────
# Stage the operator's RESEND_API_KEY into a 0600 file INSIDE the userland and have
# the launcher source it, so Maddy reads it via {env:RESEND_API_KEY} — the key never
# reaches argv / ps. The secret crosses into the userland over stdin (NOT on argv);
# re-copied each install so it survives a rootfs wipe (the large-volume RELAY_ENV is
# the source of truth). We write through proot (umask 077) rather than guessing the
# rootfs path on disk.
say "staging the relay secret into the userland + writing the Maddy launcher"
proot-distro login debian -- bash -lc "umask 077; cat > '${MADDY_DIR}/relay.env'" < "${RELAY_ENV}" \
  || die "failed to stage the relay secret into the userland"
in_debian "chmod 600 '${MADDY_DIR}/relay.env'" || true

proot-distro login debian -- bash -lc "umask 077; cat > '${MADDY_DIR}/run-maddy.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by steps/85-install-email.sh.
# Maddy binds loopback IMAP ${MAIL_IMAP_PORT} / inject ${MAIL_INJECT_PORT} /
# submission ${MAIL_SUBMISSION_PORT}; nothing public binds. The relay secret is
# sourced from a 0600 file so it reaches Maddy via {env:...}, never via argv.
set -a
MADDY_CONFIG=${MADDY_CONF}   # the global flag reads \$MADDY_CONFIG; \`run\` rejects --config
[ -f ${MADDY_DIR}/relay.env ] && . ${MADDY_DIR}/relay.env
set +a
cd ${MADDY_DIR}
exec ./maddy run
LAUNCH
in_debian "chmod 700 '${MADDY_DIR}/run-maddy.sh'" || die "failed to make ${MADDY_DIR}/run-maddy.sh executable"
ok "wrote the Maddy launcher"

# ── 6b. Copy the drain + write its native launcher ───────────────────────────
# The drain runs Termux-NATIVE (stdlib python3); it orchestrates the host (pulls R2
# over HTTPS, runs proot-distro to list Maddy accounts, injects over loopback SMTP).
# It is copied to the large volume so it lives beside its state.
DRAIN_DIR="${DATA_DIR}/mail"
DRAIN_DST="${DRAIN_DIR}/mail-drain.py"
say "installing the drain -> ${DRAIN_DST}"
install -m 644 "${DRAIN_SRC}" "${DRAIN_DST}" 2>/dev/null || cp -f "${DRAIN_SRC}" "${DRAIN_DST}"
require_cmd python3
python3 -c "import ast,sys; ast.parse(open('${DRAIN_DST}').read())" \
  || die "the copied drain failed to parse under python3"

# The native drain launcher sources the 0600 R2 + inject secrets under `set -a` so
# they reach the drain ONLY via the child environment (never argv / ps), exports the
# non-secret config, and fails closed if a secrets file is missing. The secret paths
# are baked in at write time; the secret VALUES are never written into the launcher.
DRAIN_LAUNCHER="${DRAIN_DIR}/run-drain.sh"
say "writing the drain launcher -> ${DRAIN_LAUNCHER}"
( umask 077; cat > "${DRAIN_LAUNCHER}" <<LAUNCH
#!/bin/bash
# Native drain launcher — sources the 0600 R2 + inject secrets into the child env
# (never argv), exports the non-secret config, then execs the drain. Fails closed if
# a secrets file is missing. Written by steps/85-install-email.sh.
set -eu
for _f in "${R2_ENV}" "${INJECT_ENV}"; do
  [ -s "\$_f" ] || { echo "mail-drain: missing secrets file \$_f" >&2; exit 1; }
done
set -a
. "${R2_ENV}"
. "${INJECT_ENV}"
INJECT_HOST=127.0.0.1
INJECT_PORT=${MAIL_INJECT_PORT}
MAIL_DOMAIN=${MAIL_DOMAIN}
MAIL_ADMIN_LOCALPART=${MAIL_ADMIN_LOCALPART}
POLL_INTERVAL=${MAIL_POLL}
DATA_DIR=${DATA_DIR}
POCKET_STATE_DIR=${POCKET_STATE_DIR}
MADDY_CONFIG=${MADDY_CONF}
PROOT_DISTRO=debian
set +a
exec python3 "${DRAIN_DST}"
LAUNCH
)
chmod 700 "${DRAIN_LAUNCHER}"
ok "wrote the drain launcher"

# ── 7. Supervise Maddy (in-proot) + the drain (native) ───────────────────────
# The shared supervisor (respawn loop + identity-checked pidfile) runs the Maddy
# launcher inside the userland with the state dir bind-mounted in.
supervise maddy -- \
  proot-distro login debian \
  --bind "${MADDY_STATE_HOST}:${MADDY_STATE_USERLAND}" \
  -- bash "${MADDY_DIR}/run-maddy.sh"

# The drain is supervised NATIVE (it must run proot-distro itself, so it can't live
# inside proot). The launcher was written + chmod 700 just above; the guard is a
# belt-and-suspenders against a failed write.
if [ -x "${DRAIN_LAUNCHER}" ]; then
  supervise mail-drain -- bash "${DRAIN_LAUNCHER}"
else
  warn "drain launcher missing/not executable (${DRAIN_LAUNCHER}) — mail-drain NOT supervised; re-run this step"
fi

# ── 8. Health-check the IMAP port ────────────────────────────────────────────
say "waiting for the Maddy IMAP listener on 127.0.0.1:${MAIL_IMAP_PORT}"
healthy=0
for _ in $(seq 1 40); do
  if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('127.0.0.1',${MAIL_IMAP_PORT}))==0 else 1)" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
[ "${healthy}" -eq 1 ] && ok "Maddy IMAP listening on 127.0.0.1:${MAIL_IMAP_PORT}" \
  || warn "Maddy IMAP did not come up on 127.0.0.1:${MAIL_IMAP_PORT} yet — check ${POCKET_LOG_DIR}/maddy.log"

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "email backend installed + supervised (Maddy in-proot on loopback; drain native)"
say "Mail domain: ${MAIL_DOMAIN}  |  IMAP 127.0.0.1:${MAIL_IMAP_PORT}  |  inject :${MAIL_INJECT_PORT}  |  submission :${MAIL_SUBMISSION_PORT}"
echo
say "Cloudflare-side steps (NOT done by this script — see scripts/email/worker/README.md):"
say "  1. Deploy the Email Worker (scripts/email/worker/) with wrangler on YOUR account."
say "  2. Point an Email Routing catch-all *@${MAIL_DOMAIN} -> that Worker."
say "  3. Create the R2 bucket + a bucket-scoped token (filled into ${R2_ENV})."
say "  4. Add the Resend API key to ${RELAY_ENV} for outbound."
say "Verify inbound:  python3 ${DATA_DIR}/mail/mail-drain.py  (ONESHOT=1 for one pass) — or check R2 with scripts/email/r2-check.py."

# Generalized from a working deployment; review before running.
