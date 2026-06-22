#!/usr/bin/env bash
#
# ops/update.sh — safely bump a pinned component and roll back if it breaks.
#
# The version + checksum of every fetched/built component lives in ONE place,
# config/versions.env. This script changes a pin there, re-runs that component's
# install step, restarts its service, watches it settle, and AUTOMATICALLY ROLLS
# BACK the pin (and reinstalls the previous version) if the service crash-loops.
#
# It is DRY-RUN by default — with no --confirm it only prints the plan, so an
# update is never a single mis-keystroke.
#
#   scripts/ops/update.sh --list                         # show every pin + tier
#   scripts/ops/update.sh <component>                     # show the plan (dry run)
#   scripts/ops/update.sh <component> --to <ver> [--sha256 <hash>]      # still dry run
#   scripts/ops/update.sh <component> --to <ver> --sha256 <hash> --confirm   # APPLY
#
# Tiers (how a rollback behaves):
#   binary / source / app — safe: a failed update reinstalls the previous version
#                           and restarts. (app = also has on-disk data; back it up.)
#   static                — served by Caddy, no service to restart.
#   schema (Matrix)       — a DB-schema migration is NOT auto-reversible. We
#                           snapshot the DB first; on failure we restore the PIN
#                           but you must run scripts/ops/restore.sh to recover the
#                           DB if the old binary can't open a migrated database.
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

VERSIONS="${POCKET_ROOT}/config/versions.env"
[ -f "$VERSIONS" ] || die "no config/versions.env at $VERSIONS"

# ── Component registry: name -> ver-var | sha-var(- if none) | step | svc(- if none) | tier
declare -A U_VERVAR U_SHAVAR U_STEP U_SVC U_TIER
reg() { U_VERVAR[$1]="$2"; U_SHAVAR[$1]="$3"; U_STEP[$1]="$4"; U_SVC[$1]="$5"; U_TIER[$1]="$6"; }
#    name         ver-var            sha-var             step                            service         tier
reg cloudflared   CF_VER             CF_SHA256           steps/20-install-cloudflared.sh  cloudflared     binary
reg matrix        CW_VER             CW_SHA256           steps/40-install-matrix.sh       matrix          schema
reg element       EL_VER             EL_SHA256           steps/50-install-element.sh      -               static
reg memos         MEMOS_VER          MEMOS_SHA256        apps/memos.sh                    memos           app
reg vikunja       VIKUNJA_VERSION    VIKUNJA_SHA256      apps/vikunja.sh                  vikunja         app
reg freshrss      FRESHRSS_VERSION   FRESHRSS_SHA256     apps/freshrss.sh                 freshrss        app
reg ittools       ITTOOLS_VERSION    ITTOOLS_ZIP_SHA256  apps/ittools.sh                  -               static
reg gatus         GATUS_VER          -                   apps/gatus.sh                    gatus           source
reg pingvin       PINGVIN_TAG        -                   apps/pingvin.sh                  pingvin         source
reg linkding      LINKDING_VERSION   -                   apps/linkding.sh                 linkding        source
reg searxng       SEARXNG_REF        -                   apps/searxng.sh                  searxng         source
reg snappymail    SNAPPYMAIL_VERSION SNAPPYMAIL_SHA256   steps/86-install-webmail.sh      snappymail-fpm  app
reg maddy         MADDY_VERSION      MADDY_SHA256         steps/85-install-email.sh        maddy           binary

# ── versions.env read/write helpers (comment-preserving, injection-safe) ──────
# get_default FILE VAR -> prints the current default inside VAR="${VAR:-DEFAULT}".
get_default() {
  awk -v var="$2" '
    index($0, var"=\"${"var":-")==1 {
      pre=var"=\"${"var":-"; rest=substr($0,length(pre)+1)
      cb=index(rest,"}\""); print substr(rest,1,cb-1); exit }' "$1"
}
# set_pin FILE VAR VAL -> rewrite VAR="${VAR:-OLD}"  (keeps any trailing comment).
set_pin() {
  local file="$1" var="$2" val="$3"
  awk -v var="$var" -v val="$val" '
    index($0, var"=\"${"var":-")==1 {
      pre=var"=\"${"var":-"; rest=substr($0,length(pre)+1)
      cb=index(rest,"}\""); tail=substr(rest,cb)
      print pre val tail; next }
    { print }' "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
}

known_names() { printf '%s\n' "${!U_VERVAR[@]}" | sort | tr '\n' ' '; }

# ── --list ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
  printf '%-14s %-8s %-22s %s\n' COMPONENT TIER VERSION SHA256
  for n in $(known_names); do
    ver="$(get_default "$VERSIONS" "${U_VERVAR[$n]}")"
    sha="-"; [ "${U_SHAVAR[$n]}" != "-" ] && sha="$(get_default "$VERSIONS" "${U_SHAVAR[$n]}")"
    printf '%-14s %-8s %-22s %s\n' "$n" "${U_TIER[$n]}" "$ver" "${sha:0:16}"
  done
  exit 0
fi

# ── Parse: <component> [--to V] [--sha256 H] [--confirm] ─────────────────────
name="${1:-}"
[ -n "$name" ] || die "usage: update.sh --list | <component> [--to <ver>] [--sha256 <hash>] [--confirm]
known components: $(known_names)"
[ -n "${U_VERVAR[$name]:-}" ] || die "unknown component '$name' — known: $(known_names)"
shift
TO="" SHA="" CONFIRM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)      TO="${2:-}"; shift 2 ;;
    --sha256)  SHA="${2:-}"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    *) die "unexpected arg: $1" ;;
  esac
done

vervar="${U_VERVAR[$name]}"; shavar="${U_SHAVAR[$name]}"
step="${U_STEP[$name]}"; svc="${U_SVC[$name]}"; tier="${U_TIER[$name]}"
cur_ver="$(get_default "$VERSIONS" "$vervar")"
cur_sha="-"; [ "$shavar" != "-" ] && cur_sha="$(get_default "$VERSIONS" "$shavar")"

# ── Show the plan (always) ───────────────────────────────────────────────────
say "component : $name   (tier: $tier)"
say "pin var   : $vervar = $cur_ver${shavar:+   $( [ "$shavar" != "-" ] && echo "$shavar = ${cur_sha:0:16}…" )}"
say "step      : scripts/$step"
say "service   : ${svc}"
[ -n "$TO" ] && say "target    : $vervar -> $TO${SHA:+   $shavar -> ${SHA:0:16}…}"

# ── Validate target (only when applying / a target was given) ────────────────
if [ -n "$TO" ]; then
  case "$TO" in *'|'*|"") die "invalid --to value" ;; esac
  printf '%s' "$TO" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || die "invalid --to '$TO' (allowed: letters, digits, . _ - /)"
  if [ "$shavar" = "-" ]; then
    [ -z "$SHA" ] || die "$name is a source/static-pin component — it has no sha256; drop --sha256"
  else
    [ -n "$SHA" ] || die "$name is sha256-pinned — you must pass --sha256 <hash> for the new version (fetch_verified fails closed)"
    printf '%s' "$SHA" | grep -qE '^[0-9a-f]{64}$' || die "invalid --sha256 (need 64 lowercase hex chars)"
  fi
fi

# ── Dry run unless --confirm ─────────────────────────────────────────────────
if [ "$CONFIRM" -ne 1 ] || [ -z "$TO" ]; then
  [ -z "$TO" ] && warn "no --to given — nothing to change."
  echo
  say "DRY RUN. To apply:"
  say "  scripts/ops/update.sh $name --to <ver>${shavar:+ $( [ "$shavar" != "-" ] && echo "--sha256 <hash>" )} --confirm"
  [ "$tier" = "schema" ] && warn "tier=schema: the DB is snapshotted first; a downgrade after a schema migration needs scripts/ops/restore.sh."
  [ "$tier" = "app" ] && warn "tier=app: this component has on-disk data — back it up (scripts/ops/backup-all.sh) before a major bump."
  exit 0
fi

# ── APPLY ────────────────────────────────────────────────────────────────────
ts="$(date -u +%Y%m%dT%H%M%SZ)"
backup="${VERSIONS}.bak-${ts}"
cp -f "$VERSIONS" "$backup"
ok "backed up versions.env -> $(basename "$backup")"

rollback() {  # rollback "reason"
  warn "ROLLBACK ($1): restoring previous pins from $(basename "$backup")"
  cp -f "$backup" "$VERSIONS"
  say "reinstalling previous $name ($cur_ver)"
  bash "${POCKET_ROOT}/scripts/$step" || warn "reinstall of previous version reported an error — check logs"
  [ "$svc" != "-" ] && { bash "${POCKET_ROOT}/scripts/ops/restart.sh" "$svc" || true; }
  if [ "$tier" = "schema" ]; then
    warn "Matrix DB may have been migrated by the newer build. If it won't start with the"
    warn "restored binary, recover the snapshot: scripts/ops/restore.sh --confirm=ERASE-AND-RESTORE"
  fi
  die "update of '$name' rolled back."
}

# schema tier: snapshot the DB before touching anything.
if [ "$tier" = "schema" ]; then
  say "snapshotting the Matrix DB first (tier=schema)"
  bash "${POCKET_ROOT}/scripts/ops/backup-db.sh" || die "DB snapshot failed — refusing to update without a restore point"
fi

# Apply the new pin(s).
set_pin "$VERSIONS" "$vervar" "$TO"
[ "$shavar" != "-" ] && set_pin "$VERSIONS" "$shavar" "$SHA"
ok "pin updated: $vervar -> $TO"

# Re-run the install step (fetch_verified re-downloads + verifies the new artifact).
say "re-running scripts/$step"
bash "${POCKET_ROOT}/scripts/$step" || rollback "install step failed"

# Restart + settle (static components have no service).
if [ "$svc" != "-" ]; then
  bash "${POCKET_ROOT}/scripts/ops/restart.sh" "$svc" || rollback "restart failed"
  wait="${UPDATE_HEALTH_WAIT:-75}"; waited=0
  say "watching '$svc' for ${wait}s to confirm it stays up…"
  while [ "$waited" -lt "$wait" ]; do
    sleep 5; waited=$((waited + 5))
    if is_degraded "$svc"; then rollback "service '$svc' went DEGRADED (crash-looping)"; fi
    pid="$(cat "${POCKET_STATE_DIR}/${svc}.pid" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then rollback "supervisor for '$svc' is not running"; fi
  done
fi

ok "updated '$name' to $TO and it is healthy. (previous pins kept at $(basename "$backup"))"
