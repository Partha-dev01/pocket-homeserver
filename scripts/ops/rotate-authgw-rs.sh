#!/usr/bin/env bash
#
# ops/rotate-authgw-rs.sh — rotate the Matrix-SSO auth gateway's RS256 OIDC signing
# key (the key that signs id_tokens for native-OIDC app clients, e.g. Vikunja /
# Gatus) with a zero-downtime kid-OVERLAP window.
#
# WHY: the RS256 realm signs id_tokens with ONE static key (authgw-rsa.json, made
# once by steps/60-install-auth-gw.sh). If that key leaks, an attacker can forge an
# admin id_token. This rotates it: mint a NEW key under a NEW kid, keep the OLD
# public key published in the JWKS for an overlap window (so id_tokens already
# issued under the old kid still validate at the relying parties), then — on a
# second invocation after the window — drop the old key.
#
# The gateway already supports this (scripts/gateway/matrix-auth-gw.py): it signs
# with AUTHGW_OIDC_RS_KID + AUTHGW_OIDC_RS_KEY_FILE and ADDITIONALLY publishes every
# key listed in AUTHGW_OIDC_RS_OLD_KEYS (`kid:/path.json` pairs) in the JWKS —
# never signing with them. steps/60's launcher sources those from
# ${DATA_DIR}/auth-gw/oidc-clients.env, so this script tells you exactly what to
# set there.
#
# This is a deliberate, operator-driven ops action (NOT scheduled). It only runs
# when the auth gateway is enabled (ENABLE_AUTH_GATEWAY=true).
#
# Usage:
#   bash scripts/ops/rotate-authgw-rs.sh new        # phase 1: mint new key, keep old in JWKS (overlap)
#   bash scripts/ops/rotate-authgw-rs.sh finalize    # phase 2 (after the overlap window): drop old key
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Gate: the auth gateway must be enabled ────────────────────────────────────
if [ "${ENABLE_AUTH_GATEWAY:-false}" != "true" ]; then
  warn "the auth gateway is not enabled (ENABLE_AUTH_GATEWAY != true) — nothing to rotate"
  say "enable it in .env + run scripts/steps/60-install-auth-gw.sh first."
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd proot-distro

PHASE="${1:-}"

# Where steps/60 stores the gateway data on the large volume + binds it into the
# userland. We touch the HOST path directly; the in-userland openssl + keygen
# helper run with this dir bind-mounted (same wiring as steps/60-install-auth-gw.sh).
GW_DATA_HOST="${DATA_DIR}/auth-gw"
GW_DATA_USERLAND="/opt/matrix-auth-gw/data"
GW_DIR="/opt/matrix-auth-gw"
CUR_KEY_HOST="${GW_DATA_HOST}/authgw-rsa.json"        # the key the gateway signs with
KID_STATE="${GW_DATA_HOST}/authgw-rs-kid"             # records the active kid
OLD_STATE="${GW_DATA_HOST}/authgw-rs-old-keys"        # records the overlap "kid:/path" list

[ -d "${GW_DATA_HOST}" ] || die "${GW_DATA_HOST} not found — run scripts/steps/60-install-auth-gw.sh first"

# ── SECURITY CARVE-OUT — keypair generation + JWK encoding ────────────────────
# TODO(human): implement _genkey. It must produce a fresh RSA private key in the
# EXACT JSON shape the gateway loads (compact {"n","e","d"} decimal-string JSON),
# writing it to $1 with 0600 perms, atomically (write to "$1.tmp", verify non-empty,
# then mv). Reuse the repo's proven primitives — do NOT hand-roll RSA:
#
#   * the in-proot openssl pipeline + the committed keygen helper, exactly as
#     steps/60-install-auth-gw.sh line ~136 does:
#       proot-distro login debian --bind "${GW_DATA_HOST}:${GW_DATA_USERLAND}" \
#         -- bash -lc "
#           set -e; umask 077
#           openssl genrsa 2048 \
#             | openssl rsa -outform DER -traditional \
#             | python3 ${GW_DIR}/rsa-der-to-jwk.py > '${GW_DATA_USERLAND}/<dest>.tmp'
#           [ -s '${GW_DATA_USERLAND}/<dest>.tmp' ] && mv '${GW_DATA_USERLAND}/<dest>.tmp' '${GW_DATA_USERLAND}/<dest>'
#           chmod 600 '${GW_DATA_USERLAND}/<dest>'
#         "
#     (rsa-der-to-jwk.py == scripts/gateway/rsa-der-to-jwk.py, already copied into
#      ${GW_DIR} by steps/60; verify it is present before relying on it.)
#   * the bind-mount maps ${GW_DATA_HOST} ↔ ${GW_DATA_USERLAND}, so a "$1" given as
#     a HOST path must be translated to its userland path inside the proot command.
#   * key SIZE: keep it consistent with steps/60 (2048) unless you deliberately
#     harden to 3072 — match whatever the gateway/relying parties expect.
#   * fail closed: if the produced file is empty or missing, `die` — never leave a
#     partial/zero-length signing key in place.
#
# This whole function is the security-critical core.
_genkey() {
  local out="$1"
  local base userland
  base="$(basename "$out")"
  # $out is a HOST path under ${GW_DATA_HOST}; translate it to its userland path
  # (the bind mount maps ${GW_DATA_HOST} ↔ ${GW_DATA_USERLAND}). All dest files
  # this script asks for live directly under ${GW_DATA_HOST}/, so a basename swap
  # onto ${GW_DATA_USERLAND} is exact.
  userland="${GW_DATA_USERLAND}/${base}"
  # Generate inside the userland (openssl + python3 + the keygen helper live there)
  # with the data dir bind-mounted, so the result materialises at the host path
  # $out. Same pipeline + key size (2048) as steps/60-install-auth-gw.sh, feeding
  # the committed scripts/gateway/rsa-der-to-jwk.py (copied to ${GW_DIR} by step 60)
  # to emit the compact {"n","e","d"} decimal-string JSON the gateway loads. Write
  # to "<dest>.tmp" then mv, so a partial pipe never leaves a usable key in place.
  proot-distro login debian \
    --bind "${GW_DATA_HOST}:${GW_DATA_USERLAND}" \
    -- bash -lc "
      set -e
      umask 077
      [ -f '${GW_DIR}/rsa-der-to-jwk.py' ] \
        || { echo 'keygen helper ${GW_DIR}/rsa-der-to-jwk.py missing — re-run scripts/steps/60-install-auth-gw.sh' >&2; exit 1; }
      o='${userland}'
      openssl genrsa 2048 2>/dev/null \
        | openssl rsa -outform DER -traditional 2>/dev/null \
        | python3 '${GW_DIR}/rsa-der-to-jwk.py' > \"\${o}.tmp\" 2>/dev/null
      [ -s \"\${o}.tmp\" ] || { rm -f \"\${o}.tmp\"; echo 'RS256 keygen produced no output' >&2; exit 1; }
      mv \"\${o}.tmp\" \"\${o}\"
      chmod 600 \"\${o}\"
    " 2>&1 | grep -v 'proot warning' >&2 || true
  # Fail closed on the HOST path (the bind mount only exists during the command
  # above). An empty / missing key here must never be promoted to live signing.
  [ -s "$out" ] || die "rotate-authgw-rs: _genkey produced no key at $out (is the gateway installed? see scripts/steps/60-install-auth-gw.sh)"
  chmod 600 "$out" 2>/dev/null || true
}

case "$PHASE" in
  new)
    [ -s "${CUR_KEY_HOST}" ] || die "no current signing key at ${CUR_KEY_HOST} — start the gateway once (steps/60-install-auth-gw.sh) first"

    NEW_KID="authgw-rs256-$(date -u +%Y%m%d)"
    OLD_KID="$(cat "${KID_STATE}" 2>/dev/null || echo "authgw-rs256")"
    NEW_KEY="${GW_DATA_HOST}/authgw-rsa-${NEW_KID}.json"
    OLD_KEY="${GW_DATA_HOST}/authgw-rsa-${OLD_KID}.json"

    say "rotation PHASE 1: minting a new RS256 signing key (kid=${NEW_KID})"
    umask 077
    # Preserve the CURRENT key under its kid-named file so it can stay in the JWKS
    # during the overlap window (the gateway publishes it but never signs with it).
    cp "${CUR_KEY_HOST}" "${OLD_KEY}"; chmod 600 "${OLD_KEY}" 2>/dev/null || true
    # Mint the new key, then promote it to the live signing-key path.
    _genkey "${NEW_KEY}" || die "keygen failed"
    [ -s "${NEW_KEY}" ] || die "new key was not produced at ${NEW_KEY}"
    cp "${NEW_KEY}" "${CUR_KEY_HOST}"; chmod 600 "${CUR_KEY_HOST}" 2>/dev/null || true
    printf '%s\n' "${NEW_KID}" > "${KID_STATE}"; chmod 600 "${KID_STATE}" 2>/dev/null || true
    printf '%s:%s\n' "${OLD_KID}" "${OLD_KEY}" > "${OLD_STATE}"; chmod 600 "${OLD_STATE}" 2>/dev/null || true

    cat >&2 <<EOF

  ── auth-gw RS256 rotation phase 1 complete ───────────────────────────────────
  NEW signing key : ${NEW_KEY} (kid=${NEW_KID})
  OLD key in JWKS during overlap : ${OLD_KEY} (kid=${OLD_KID})

  NOW set these in ${GW_DATA_HOST}/oidc-clients.env (0600; the launcher sources it),
  then restart the gateway:
      AUTHGW_OIDC_RS_KID=${NEW_KID}
      AUTHGW_OIDC_RS_OLD_KEYS=${OLD_KID}:${GW_DATA_USERLAND}/$(basename "${OLD_KEY}")
  (AUTHGW_OIDC_RS_KEY_FILE stays ${GW_DATA_USERLAND}/authgw-rsa.json = the new key.)

      bash ${POCKET_ROOT}/scripts/ops/restart.sh auth-gw

  Verify: the JWKS lists BOTH kids and your OIDC apps still log in. Wait longer
  than the OIDC token TTL + the clients' JWKS cache, then run:
      bash ${POCKET_ROOT}/scripts/ops/rotate-authgw-rs.sh finalize
  ──────────────────────────────────────────────────────────────────────────────
EOF
    ok "phase 1 done — set the env above, restart auth-gw, then finalize after the overlap window"
    ;;

  finalize)
    say "rotation PHASE 2: dropping the old key from the JWKS overlap"
    cat >&2 <<EOF

  Clear the overlap so only the current key remains published — in
  ${GW_DATA_HOST}/oidc-clients.env set:
      AUTHGW_OIDC_RS_OLD_KEYS=
  then restart:
      bash ${POCKET_ROOT}/scripts/ops/restart.sh auth-gw

  After confirming clients still validate, you may delete the retired key file
  recorded in ${OLD_STATE}.
EOF
    rm -f "${OLD_STATE}"
    ok "phase 2 instructions printed — clear AUTHGW_OIDC_RS_OLD_KEYS + restart auth-gw"
    ;;

  *)
    die "usage: $0 {new|finalize}"
    ;;
esac
