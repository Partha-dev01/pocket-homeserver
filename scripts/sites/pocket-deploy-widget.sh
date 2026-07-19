#!/data/data/com.termux/files/usr/bin/bash
# pocket-homeserver widget-deploy shortcut (ENABLE_SITES_WIDGET_DEPLOY)
#
# pocket-deploy-widget.sh — one-tap, on-phone deploy via a Termux:Widget
# home-screen shortcut. The secondary path KEPT alongside the share-sheet
# hook by CORRECTION C-1 (docs/specs/SPEC-DIFFERENTIATORS.md §7.3/§7.5) —
# installed AT ~/.shortcuts/pocket-deploy.sh by scripts/apps/sites.sh
# (ENABLE_SITES_WIDGET_DEPLOY=true).
#
# Termux:Widget (a separate F-Droid companion app, same family as
# Termux:Boot which this repo already documents,
# scripts/steps/75-install-boot.sh:17-18,81) runs any script under
# ~/.shortcuts/ in a REAL foreground Termux session when its home-screen icon
# is tapped (verified against Termux:Widget's own docs, SPEC §16-EXT-7) —
# termux-* commands behave normally, and site-deploy.sh's tty-only staging
# exemption (scripts/sites/site-deploy.sh:84-94) applies here for the exact
# same reason it applies to pocket-share-hook.sh.
#
# NOT the Android Share Sheet: tapping this widget opens the system Storage
# Access Framework document picker (termux-storage-get), not a Share target.
# The realistic flow is two steps, not one ("share/save a zip somewhere from
# another app, THEN tap this widget and pick it") — documented honestly, not
# marketed as literally one-tap end to end (SPEC §7.3).

set -euo pipefail

# SUB_RE, scripts/sites/lib-sites.sh:43 — duplicated here as a belt-only,
# fail-fast check (mirrors pocket-share-hook.sh and admin/app.py's own
# SITE_SUB_RE). site-deploy.sh's own validate_site_name() remains the ONE
# authoritative gate.
SITE_SUB_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# POCKET_ROOT: baked in at install time by scripts/apps/sites.sh, same
# reasoning as pocket-share-hook.sh's header comment (this script is also a
# plain out-of-tree file copy, at ~/.shortcuts/pocket-deploy.sh). The
# environment wins when already set — the seam tests/test_sites_ondevice.py
# uses.
POCKET_ROOT="${POCKET_ROOT:-__POCKET_ROOT__}"

# The phone has NO /tmp — every on-phone temp path in this repo is
# $HOME-rooted (${TMPDIR:-$HOME/.cache} style), never /tmp.
TMP_DIR="${TMPDIR:-$HOME/.cache}"
mkdir -p "${TMP_DIR}"
TMP_ZIP="${TMP_DIR}/pocket-deploy-widget-$$.zip"

cleanup() { rm -f "${TMP_ZIP}"; }
trap cleanup EXIT

# _report KIND MESSAGE — see pocket-share-hook.sh for the identical shape.
_report() {
  local kind="$1" msg="$2" title="Pocket Pages deploy"
  [ "${kind}" = failure ] && title="Pocket Pages deploy FAILED"
  printf '%s: %s\n' "${title}" "${msg}" >&2
  command -v termux-notification >/dev/null 2>&1 \
    && { termux-notification --title "${title}" --content "${msg}" >/dev/null 2>&1 || true; }
  command -v termux-toast >/dev/null 2>&1 \
    && { termux-toast "${msg}" >/dev/null 2>&1 || true; }
  # Explicit return 0 -- see pocket-share-hook.sh's identical _report() for
  # why this is required under `set -e` (a bare function call is not exempt
  # from -e the way an inline `cmdA && cmdB` is when cmdA alone fails).
  return 0
}

# Guard FIRST (spec §7.5): fail fast, toast+exit, before any prompt/picker.
if ! command -v termux-storage-get >/dev/null 2>&1; then
  command -v termux-toast >/dev/null 2>&1 \
    && { termux-toast "Termux:API not installed" >/dev/null 2>&1 || true; }
  echo "Termux:API not installed -- install it from F-Droid to use this widget (see docs/SITES.md)" >&2
  exit 1
fi

# _dialog_text_field JSON — identical to pocket-share-hook.sh's helper; see
# that script's comment for why this avoids python3 (not guaranteed on the
# Termux HOST side) and avoids piping through `head` (SIGPIPE risk under
# `set -o pipefail`).
_dialog_text_field() {
  local raw
  raw="$(printf '%s' "$1" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p')"
  printf '%s' "${raw%%$'\n'*}"
}

# ── site-name prompt FIRST (fail fast on a bad name, before the picker) ─────
SITE=""
if command -v termux-dialog >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    DIALOG_JSON="$(timeout 60 termux-dialog text -t "Deploy site name" 2>/dev/null || true)"
  else
    DIALOG_JSON="$(termux-dialog text -t "Deploy site name" 2>/dev/null || true)"
  fi
  SITE="$(_dialog_text_field "${DIALOG_JSON}")"
else
  read -r -p "Deploy site name: " SITE || SITE=""
fi

if [ -z "${SITE}" ]; then
  exit 0  # cancelled -- quietly do nothing, same as the share hook
fi

if ! [[ ${SITE} =~ ${SITE_SUB_RE} ]]; then
  _report failure "invalid site name '${SITE}' (lowercase letters/digits/hyphen, 1..63 chars) -- fail fast, before the file picker opens"
  exit 1
fi

# ── file picker ───────────────────────────────────────────────────────────────
# Opens the system Storage Access Framework document picker; copies whatever
# the operator chooses into TMP_ZIP. A directory pick isn't representable
# through this picker -- a real, accepted limitation (SPEC §7.5), not hidden.
if ! termux-storage-get "${TMP_ZIP}"; then
  _report failure "file picker cancelled or failed -- deploy not attempted"
  exit 1
fi

if [ ! -s "${TMP_ZIP}" ]; then
  _report failure "no file was picked (empty result) -- deploy not attempted"
  exit 1
fi

# termux-storage-get copies bytes into a destination WE name (it does not
# preserve the picked file's own name/extension) — TMP_ZIP already ends in
# .zip by construction, so there is no separate "is this really a zip"
# extension check to run here beyond the non-empty check above. That matches
# the rest of this pipeline: site-deploy.sh's own zip-vs-directory dispatch
# (site-deploy.sh:349) also keys off the artifact's extension, never magic
# bytes, so this widget introduces no new content-shape gap — a non-zip file
# picked by the operator simply fails site-deploy.sh's own extraction step
# below with a clear error, exactly like a bad CLI/panel upload would.

DEPLOY_SCRIPT="${POCKET_ROOT}/scripts/sites/site-deploy.sh"
if [ ! -f "${DEPLOY_SCRIPT}" ]; then
  _report failure "pocket-homeserver not found at ${POCKET_ROOT} -- re-run scripts/apps/sites.sh (ENABLE_SITES_WIDGET_DEPLOY=true) to reinstall this widget"
  exit 1
fi

rc=0
bash "${DEPLOY_SCRIPT}" "${SITE}" "${TMP_ZIP}" || rc=$?
if [ "${rc}" -eq 0 ]; then
  _report success "${SITE} deployed"
else
  _report failure "deploy of '${SITE}' exited ${rc} -- see the terminal output above"
  exit "${rc}"
fi
