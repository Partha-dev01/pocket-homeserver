#!/usr/bin/env bash
#
# apps/vaultwarden.sh — install + supervise Vaultwarden (the Rust, Bitwarden-
# compatible password-manager server) as an OPTIONAL app behind the loopback
# Caddy edge, on vault.${DOMAIN}.
#
# ┌── SUPPLY-CHAIN REALITY — READ THIS ─────────────────────────────────────────
# │ Vaultwarden ships NO official standalone binary (its GitHub releases carry
# │ ZERO downloadable assets — only Docker images). Building from source is
# │ INFEASIBLE on a phone (cargo release builds peak ~4-7 GB RAM → the Android
# │ Low-Memory-Killer + thermal throttle; upstream issue #6314). So we do what the
# │ upstream wiki documents: EXTRACT the musl-static binary + the version-locked
# │ web-vault from the OFFICIAL `vaultwarden/server:<ver>-alpine` image — but with
# │ NO Docker daemon. We pull the arm64 image MANIFEST by its pinned @sha256
# │ digest from the Docker registry over HTTPS, verify EACH layer blob against its
# │ manifest digest (fail-closed), assemble the rootfs, extract /vaultwarden +
# │ /web-vault, and additionally verify the extracted binary against a sha256 the
# │ maintainer derived himself and pinned below. Integrity is therefore rooted at
# │ the OFFICIAL IMAGE DIGEST (content-addressed) plus a self-derived binary hash —
# │ NOT a clean upstream-signed binary checksum. This is materially weaker than a
# │ dufs-style upstream release asset, and EVERY upgrade requires re-deriving both
# │ the binary hash AND the matched web-vault version. Documented honestly here and
# │ in docs/VAULT.md as "extracted from the official Alpine image @ pinned digest".
# └─────────────────────────────────────────────────────────────────────────────
#
# What it does (idempotent — review before running):
#   1. daemonless-pulls the pinned arm64 image @ digest, verifies every layer,
#      extracts /vaultwarden (sha256-checked fail-closed) + /web-vault into the
#      userland at /opt/vaultwarden (musl-static runs fine on glibc Debian),
#   2. keeps ALL state (db.sqlite3 + -wal/-shm, rsa_key JWT signing keys,
#      attachments, sends) on ext4 ($HOME/.pocket/vaultwarden, bind-mounted to
#      /opt/vaultwarden/data) — NEVER on the exFAT SD card,
#   3. writes a hardened 0600 .env (ROCKET_ADDRESS=127.0.0.1, SIGNUPS_ALLOWED=false,
#      ADMIN_TOKEN UNSET so /admin is disabled, ENABLE_DB_WAL=true, DOMAIN set) and
#      ASSERTS the loopback bind fail-closed,
#   4. writes a self-contained Caddy vhost + validates fail-closed (no Caddy restart),
#   5. supervises the single binary on loopback via the shared lib.
#
# AUTH MODEL — sharp edge: Vaultwarden's clients (browser extension, desktop,
# mobile, CLI) speak the NATIVE Bitwarden token API and CANNOT follow a 302-to-
# login. So vault.${DOMAIN} must NOT sit behind the interactive forward_auth /
# Matrix-SSO / Cloudflare-Access redirect — that would break every native client.
# Security = Vaultwarden's OWN master-password + 2FA, plus an operator-side
# Cloudflare Access SERVICE-TOKEN exemption for vault.${DOMAIN} (this script wires
# nothing for it). SIGNUPS_ALLOWED=false means accounts are invite/admin-only, so
# set it BEFORE first exposure. See docs/VAULT.md + docs/APP_AUTH.md.
#
# Generalized from the dufs app pattern; review before running.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN   "your public domain, e.g. example.com"
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_VAULTWARDEN=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned image + self-derived artifact hashes ──────────────────────────────
# VAULTWARDEN_TAG is informational (the human-readable version). The DETERMINISTIC
# anchor is VAULTWARDEN_MANIFEST_ARM64 — the @sha256 digest of the linux/arm64
# image manifest — from which the layer blobs (each digest-verified) and thus the
# extracted files are reproducible. VAULTWARDEN_BIN_SHA256 is the sha256 of the
# EXTRACTED /vaultwarden binary, derived by the maintainer (see header). The
# web-vault is version-locked to the server; we assert its version.json matches.
# To upgrade: pull the new <ver>-alpine image, read its linux/arm64 manifest
# digest, extract + sha256 the new binary, note the new web-vault version, and
# bump ALL FOUR together. Do NOT invent a hash.
VAULTWARDEN_TAG="${VAULTWARDEN_TAG:-1.36.0-alpine}"
VAULTWARDEN_REPO="${VAULTWARDEN_REPO:-vaultwarden/server}"
VAULTWARDEN_MANIFEST_ARM64="${VAULTWARDEN_MANIFEST_ARM64:-sha256:a925c18b92e794fb199026003e9c22e4fa0e5d44cf53abc98dc15eb91e1ba2a4}"
VAULTWARDEN_BIN_SHA256="${VAULTWARDEN_BIN_SHA256:-dfdf0b37bc6289cbd0fc082aa79451173b12256d396fb953137a3b857755bcbe}"
VAULTWARDEN_WEBVAULT_VERSION="${VAULTWARDEN_WEBVAULT_VERSION:-2026.4.1}"

# ── Service coordinates ──────────────────────────────────────────────────────
VW_PORT="${VAULTWARDEN_PORT:-9122}"             # loopback bind; only Caddy reaches it
VW_HOST="vault.${DOMAIN}"                         # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/vaultwarden                     # in userland — binary + web-vault + .env
BIN="${INSTALL_DIR}/vaultwarden"
WEBVAULT_DIR="${INSTALL_DIR}/web-vault"
ENV_FILE="${INSTALL_DIR}/.env"                    # 0600 in userland; vaultwarden auto-loads it
DATA_MOUNT="${INSTALL_DIR}/data"                  # in userland — DATA_FOLDER (bind target)

# ALL state on ext4 (NOT exFAT). db.sqlite3 + -wal/-shm need real fsync + atomic
# rename + unix locks; the rsa_key JWT signing keys + attachments live here too.
DATA_BACKING="${HOME}/.pocket/vaultwarden"        # on ext4 (host) — survives a rootfs rebuild
CACHE_DIR="${DATA_DIR}/binaries"

# ── Data dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ───────────────────
assert_ext4 "${DATA_BACKING}" "Vaultwarden data dir"
mkdir -p "${DATA_BACKING}" "${CACHE_DIR}" || die "cannot create ${DATA_BACKING} on ext4"
chmod 700 "${DATA_BACKING}" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── 1. Extract the binary + web-vault from the official image (daemonless) ───
# Idempotent: skip if the installed binary already matches the pinned sha256 and
# the matched web-vault is present. Otherwise run the proven manifest-by-digest +
# per-layer-verify + assemble + extract flow INSIDE the userland (needs curl + jq).
# The pinned values are passed as POSITIONAL ARGS to a QUOTED heredoc (no parent
# expansion; nothing secret is involved — the registry pull is anonymous).
need_fetch=1
if in_debian "[ -x '${BIN}' ] && [ -f '${WEBVAULT_DIR}/version.json' ] && [ \"\$(sha256sum '${BIN}' 2>/dev/null | cut -d' ' -f1)\" = '${VAULTWARDEN_BIN_SHA256}' ]"; then
  ok "Vaultwarden binary already installed + sha256-verified at ${BIN}"
  need_fetch=0
fi

if [ "${need_fetch}" -eq 1 ]; then
  say "fetching Vaultwarden ${VAULTWARDEN_TAG} from the official image @ ${VAULTWARDEN_MANIFEST_ARM64} (daemonless, layer-verified)"
  proot-distro login debian -- bash -s \
    "${VAULTWARDEN_REPO}" "${VAULTWARDEN_MANIFEST_ARM64}" "${VAULTWARDEN_BIN_SHA256}" \
    "${VAULTWARDEN_WEBVAULT_VERSION}" "${INSTALL_DIR}" <<'FETCH'
set -e
REPO="$1"; MAN="$2"; WANT_BIN="$3"; WANT_WV="$4"; DEST="$5"
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
  apt-get update -qq
  apt-get install -y --no-install-recommends curl jq ca-certificates >/dev/null
}
STAGE="$(mktemp -d /opt/vaultwarden-stage.XXXXXX)"
ROOTFS="${STAGE}/rootfs"; mkdir -p "${ROOTFS}"
trap 'rm -rf "${STAGE}"' EXIT
# Anonymous pull token for the public repo.
TOKEN="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" | jq -r .token)"
[ -n "${TOKEN}" ] && [ "${TOKEN}" != null ] || { echo "registry token fetch failed"; exit 1; }
# Fetch the arm64 image manifest BY ITS PINNED DIGEST (content-addressed).
M="$(curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://registry-1.docker.io/v2/${REPO}/manifests/${MAN}")"
echo "${M}" | jq -e '.layers | length > 0' >/dev/null || { echo "manifest had no layers (bad digest?)"; exit 1; }
i=0
for dg in $(echo "${M}" | jq -r '.layers[].digest'); do
  i=$((i+1))
  curl -fsSL -H "Authorization: Bearer ${TOKEN}" \
    "https://registry-1.docker.io/v2/${REPO}/blobs/${dg}" -o "${STAGE}/layer.bin"
  got="$(sha256sum "${STAGE}/layer.bin" | cut -d' ' -f1)"
  [ "sha256:${got}" = "${dg}" ] || { echo "LAYER ${i} sha256 MISMATCH (want ${dg}, got sha256:${got})"; exit 1; }
  # OCI tar+gzip layer. Tolerate tar's nonzero from un-creatable /dev nodes etc.;
  # the pinned-binary sha256 below is the real integrity gate.
  tar -xzf "${STAGE}/layer.bin" -C "${ROOTFS}" 2>/dev/null || true
  rm -f "${STAGE}/layer.bin"
done
# Verify the EXTRACTED binary against the maintainer-pinned hash, fail-closed.
[ -f "${ROOTFS}/vaultwarden" ] || { echo "no /vaultwarden in the assembled rootfs"; exit 1; }
GOT_BIN="$(sha256sum "${ROOTFS}/vaultwarden" | cut -d' ' -f1)"
[ "${GOT_BIN}" = "${WANT_BIN}" ] || { echo "EXTRACTED BINARY sha256 MISMATCH (want ${WANT_BIN}, got ${GOT_BIN})"; exit 1; }
# Web-vault must be present and version-locked to the server.
[ -f "${ROOTFS}/web-vault/version.json" ] || { echo "no /web-vault/version.json extracted"; exit 1; }
grep -q "\"${WANT_WV}\"" "${ROOTFS}/web-vault/version.json" \
  || { echo "web-vault version mismatch — expected ${WANT_WV}, got: $(cat "${ROOTFS}/web-vault/version.json")"; exit 1; }
# Install atomically-ish into DEST.
mkdir -p "${DEST}"
install -m 0755 "${ROOTFS}/vaultwarden" "${DEST}/vaultwarden"
rm -rf "${DEST}/web-vault"
cp -a "${ROOTFS}/web-vault" "${DEST}/web-vault"
echo "extracted + verified vaultwarden ($GOT_BIN) + web-vault ${WANT_WV}"
FETCH
  in_debian "[ -x '${BIN}' ] && [ \"\$(sha256sum '${BIN}' | cut -d' ' -f1)\" = '${VAULTWARDEN_BIN_SHA256}' ]" \
    || die "Vaultwarden extraction/verify failed (see output above)"
  ok "Vaultwarden ${VAULTWARDEN_TAG} extracted + sha256-verified (binary ${VAULTWARDEN_BIN_SHA256}; web-vault ${VAULTWARDEN_WEBVAULT_VERSION})"
fi

# Sanity: the binary runs inside the userland.
ver="$(in_debian "${BIN} --version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "vaultwarden: ${ver}" || warn "vaultwarden --version produced no output (continuing; the supervisor will surface a real boot failure)"

# ── 2. Data dir bind target in the userland ──────────────────────────────────
in_debian "mkdir -p '${DATA_MOUNT}'" || die "failed to create ${DATA_MOUNT} mountpoint in the userland"

# ── 3. Hardened 0600 .env (loopback bind, signups off, ADMIN_TOKEN unset, WAL) ─
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ ROCKET_ADDRESS=127.0.0.1 forces loopback (Vaultwarden DEFAULTS to 0.0.0.0).
# │ SIGNUPS_ALLOWED=false → no open registration (set BEFORE first exposure).
# │ ADMIN_TOKEN is intentionally ABSENT → the /admin panel is fully DISABLED.
# │ ENABLE_DB_WAL=true MUST be present on EVERY start (booting once without it
# │ reverts journal_mode). DOMAIN is the public origin so absolute URLs/links and
# │ WebAuthn/2FA work behind the proxy. Vaultwarden auto-loads this .env from its
# │ CWD (the launcher cds into ${INSTALL_DIR}). No secrets are placed on argv.
# └────────────────────────────────────────────────────────────────────────────
say "writing the hardened ${ENV_FILE} (chmod 600)"
proot-distro login debian -- bash -lc "umask 077; cat > '${ENV_FILE}'" <<EOF
# Generated by apps/vaultwarden.sh — hardened, single-tenant Vaultwarden config.
# Vaultwarden auto-loads this .env from its working directory (${INSTALL_DIR}).

# ── loopback bind (Vaultwarden defaults to 0.0.0.0 — do NOT change) ──
ROCKET_ADDRESS=127.0.0.1
ROCKET_PORT=${VW_PORT}

# ── data + web-vault on ext4 ──
DATA_FOLDER=${DATA_MOUNT}
WEB_VAULT_FOLDER=${WEBVAULT_DIR}
WEB_VAULT_ENABLED=true

# ── hardening ──
SIGNUPS_ALLOWED=false
# ADMIN_TOKEN is deliberately UNSET → the /admin panel is disabled. If you ever
# enable it, set an ARGON2id PHC hash from \`vaultwarden hash\` (never plaintext)
# and keep it behind the service-token boundary. See docs/VAULT.md.
SHOW_PASSWORD_HINT=false
ENABLE_DB_WAL=true

# ── public origin (Caddy + the Cloudflare Tunnel terminate TLS) ──
DOMAIN=https://${VW_HOST}
EOF
in_debian "chmod 600 '${ENV_FILE}'" || true
ok "wrote ${ENV_FILE} (chmod 600)"

# ── 4. FAIL-CLOSED loopback assert ───────────────────────────────────────────
say "asserting the Vaultwarden bind is loopback (guards against the 0.0.0.0 default)"
in_debian "grep -Eq '^[[:space:]]*ROCKET_ADDRESS=127\.0\.0\.1[[:space:]]*\$' '${ENV_FILE}'" \
  || die "ROCKET_ADDRESS is NOT 127.0.0.1 — refusing to start a LAN-exposed vault (check ${ENV_FILE})"
in_debian "grep -Eq '^[[:space:]]*ROCKET_ADDRESS=0\.0\.0\.0' '${ENV_FILE}'" \
  && die "Vaultwarden .env still binds 0.0.0.0 — refusing to start (check ${ENV_FILE})" || true
in_debian "grep -Eq '^[[:space:]]*SIGNUPS_ALLOWED=false[[:space:]]*\$' '${ENV_FILE}'" \
  || die "SIGNUPS_ALLOWED is not false — refusing to start with open registration"
ok "Vaultwarden bind confirmed loopback (127.0.0.1); signups off; ADMIN_TOKEN unset"

# In-userland launcher: cd into the install dir so Vaultwarden auto-loads .env,
# then exec the binary. Keeps the supervise→proot quoting simple; no secrets on argv.
proot-distro login debian -- bash -lc "umask 077; cat > '${INSTALL_DIR}/run.sh'" <<LAUNCH
#!/bin/bash
# Runs INSIDE the Debian userland; started + kept alive by apps/vaultwarden.sh.
cd '${INSTALL_DIR}' || exit 1
exec ./vaultwarden
LAUNCH
in_debian "chmod +x '${INSTALL_DIR}/run.sh'" || die "failed to make ${INSTALL_DIR}/run.sh executable"

# ── 5. Caddy vhost (self-contained; imported by the core Caddyfile) ──────────
# Since v1.31.0 the notifications WebSocket is served on the MAIN HTTP port, so a
# single plain reverse_proxy (which auto-upgrades Connection/Upgrade) handles both
# the API and /notifications/hub — NO separate :3012 rule. Listener style matches
# the other vhosts. NO forward_auth here: native Bitwarden clients can't do a 302.
say "writing the Vaultwarden vhost → /etc/caddy/apps/vaultwarden.caddy"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/vaultwarden.caddy' <<EOF
# vault.${DOMAIN} — Vaultwarden (Bitwarden-compatible password manager).
# Written by scripts/apps/vaultwarden.sh. Loopback-only; the Cloudflare Tunnel
# forwards public traffic here. Auth = Vaultwarden's OWN master-password + 2FA.
# DO NOT put this behind the interactive forward_auth / CF Access redirect — native
# Bitwarden clients (extension/desktop/mobile/CLI) cannot follow a 302 login. Use a
# CF Access SERVICE-TOKEN exemption for this hostname instead. See docs/VAULT.md.
http://vault.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy same-origin
		-Server
	}

	# Single reverse_proxy handles the API AND the notifications WebSocket (served
	# on the main port since v1.31.0). Caddy auto-upgrades the WebSocket; no :3012.
	reverse_proxy 127.0.0.1:${VW_PORT}
}
EOF
then
  die "failed to write /etc/caddy/apps/vaultwarden.caddy into the userland"
fi

say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/vaultwarden.caddy"
ok "Vaultwarden vhost written + Caddyfile validates"

# ── 6. Supervise the single binary on loopback ───────────────────────────────
# The DATA_FOLDER is the ext4 bind so the SQLite DB + WAL + JWT keys land on a real
# filesystem. The launcher cds into ${INSTALL_DIR} so the 0600 .env auto-loads.
say "supervising Vaultwarden (static binary in the userland, bind 127.0.0.1:${VW_PORT})"
supervise vaultwarden -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- bash "${INSTALL_DIR}/run.sh"

# ── 6b. FAIL-CLOSED post-start loopback backstop (ss wildcard check) ─────────
# Vaultwarden defaults to 0.0.0.0; the ROCKET_ADDRESS assert above is backed by an
# empirical socket audit — this is the most sensitive service (it holds the vault),
# so refuse to leave a wildcard listener for :${VW_PORT} running. See lib/common.sh.
assert_loopback_listener vaultwarden "${VW_PORT}"

# ── 7. Best-effort health check ──────────────────────────────────────────────
# /alive is an unauthenticated liveness endpoint that returns a timestamp.
say "waiting for Vaultwarden to answer on 127.0.0.1:${VW_PORT}"
healthy=0
for _ in $(seq 1 40); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${VW_PORT}/alive" 2>/dev/null \
     || curl -s -m 3 -o /dev/null "http://127.0.0.1:${VW_PORT}/" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "Vaultwarden answering on 127.0.0.1:${VW_PORT}"
else
  warn "Vaultwarden not yet answering on :${VW_PORT} — check ${POCKET_LOG_DIR}/vaultwarden.log (the supervisor keeps retrying)"
fi

# ── 8. Closing notes ─────────────────────────────────────────────────────────
cat >&2 <<EOF

$(ok "Vaultwarden installed + supervised on 127.0.0.1:${VW_PORT} (data on ${DATA_BACKING})" 2>&1)

  FIRST ACCOUNT: SIGNUPS_ALLOWED=false, so open registration is OFF. Create your
  first account by temporarily allowing it, OR invite via SMTP (operator-supplied).
  The /admin panel is DISABLED (ADMIN_TOKEN unset). See docs/VAULT.md for the
  recommended first-user flow and how to enable invites safely.

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${VW_HOST}  ->  http://localhost:${CADDY_PORT}   (plain HTTP; the tunnel
       terminates public TLS).
    2. Cloudflare Access: because the Bitwarden apps use the native token API and
       CANNOT complete an interactive login redirect, add a SERVICE-TOKEN (Service
       Auth) exemption for ${VW_HOST} — do NOT put it behind a normal Access login
       policy or the apps will break. Vaultwarden's master-password + 2FA is the
       real gate. See docs/VAULT.md + docs/APP_AUTH.md.

  Upgrades: re-pull the new <ver>-alpine image @ its new arm64 digest, re-derive
  the binary sha256 AND the matched web-vault version, bump all pins together, then
  re-run. Migrations auto-run on first start and are one-way — BACK UP the DB first
  (admin panel → Backups, or scripts/ops/backup-db.sh). ENABLE_DB_WAL must stay set.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
EOF

ok "apps/vaultwarden.sh done (vault.${DOMAIN} once the Cloudflare hostname + service-token exemption are added)"

# Generalized from a working deployment; review before running.
