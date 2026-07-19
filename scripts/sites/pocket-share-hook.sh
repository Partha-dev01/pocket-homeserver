#!/data/data/com.termux/files/usr/bin/bash
# pocket-homeserver share-deploy hook (ENABLE_SITES_SHARE_DEPLOY)
#
# pocket-share-hook.sh — Android Share Sheet -> Pocket Pages deploy. This is
# the headline path of CORRECTION C-1 (docs/specs/SPEC-DIFFERENTIATORS.md,
# §7 as amended) — installed AT ~/bin/termux-file-editor by
# scripts/apps/sites.sh (ENABLE_SITES_SHARE_DEPLOY=true; that installer's
# no-clobber check keys on the marker comment above, so keep it verbatim and
# near the top).
#
# termux-file-editor is Termux's OWN global "edit a file" hook, not something
# this repo invented. termux-app's FileReceiverActivity runs it (in a REAL
# foreground Termux pty session, one new terminal per invocation) whenever:
#   (a) the operator Shares a FILE into the "Termux" target from any app's
#       Share Sheet — Android saves it to ~/downloads first (with its own
#       filename-confirm dialog), THEN execs this hook with that absolute
#       path as $1. The Share Sheet entry is labeled "Termux" (the receiving
#       app) — NOT "pocket-homeserver". Only a companion Android APK could
#       change that label, and shipping one is out of scope (SPEC §7.2/§3).
#   (b) termux-open, or a file manager, asks Termux to "edit" a file — the
#       hook's normal, pre-existing purpose, which this script MUST keep
#       working for every non-.zip file (below).
#
# Because this hook always runs in a real interactive pty (never a piped/
# detached subprocess), site-deploy.sh's non-interactive staging-containment
# check is exempt for it (scripts/sites/site-deploy.sh:84-94, `[ ! -t 0 ]`) —
# the documented "operator running this by hand from a real terminal" CLI
# convenience carve-out, not a new bypass invented here. That is also why
# this hook hands site-deploy.sh the shared file's path AS-IS (~/downloads/
# ...), instead of first copying it under .staging/.
#
# What happens to the source file: site-deploy.sh only ever COPIES bytes out
# of the artifact (cp -a / rsync / safe_extract.py, scripts/sites/
# site-deploy.sh:308-359) into the new release tree — it never unlinks,
# moves, or truncates the artifact path itself. So this hook never touches,
# consumes, or deletes "$1" either; it was placed in ~/downloads by Android/
# Termux and belongs to the operator, same as any other download.

set -euo pipefail

# SUB_RE, scripts/sites/lib-sites.sh:43 — duplicated here as a belt-only,
# fail-fast check (same convention admin/app.py:2739-2759's SITE_SUB_RE
# already uses for the panel's own belt check). site-deploy.sh's own
# validate_site_name() remains the ONE authoritative gate.
SITE_SUB_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# POCKET_ROOT: this hook is INSTALLED OUTSIDE the repo tree, as a plain FILE
# COPY at ~/bin/termux-file-editor (not a symlink) — so it cannot locate the
# repo the way an in-repo script does (scripts/lib/common.sh's
# BASH_SOURCE-relative trick only works for a script that still LIVES under
# scripts/lib/../.. at run time). scripts/apps/sites.sh instead bakes the
# resolved absolute repo path in at copy time via sed substitution of the
# __POCKET_ROOT__ placeholder below — the SAME "bake a resolved value into an
# out-of-tree, Termux-native launcher" precedent scripts/steps/
# 70-install-admin.sh already uses for ~/pocket-admin/run.sh
# (`export POCKET_ROOT='${POCKET_ROOT}'`). The environment wins when already
# set, which is the seam tests/test_sites_ondevice.py uses to point this
# script at a fixture tree without installing anything.
POCKET_ROOT="${POCKET_ROOT:-__POCKET_ROOT__}"

[ $# -ge 1 ] || { echo "usage: termux-file-editor <path>" >&2; exit 1; }
SHARED_PATH="$1"

# Nothing this hook creates needs cleanup: termux-dialog's reply is captured
# via command substitution into a shell variable, never written to disk, and
# (per the header above) the shared file at "$SHARED_PATH" is the operator's,
# not ours to remove. This trap documents that explicitly rather than
# silently having none.
cleanup() { :; }
trap cleanup EXIT

# _report KIND MESSAGE — KIND is "success" or "failure". Always echoes
# (visible in the pty Android just opened); best-effort termux-notification
# (persists if the session isn't focused) and termux-toast (quick glance),
# each independently optional — neither failing is fatal.
_report() {
  local kind="$1" msg="$2" title="Pocket Pages deploy"
  [ "${kind}" = failure ] && title="Pocket Pages deploy FAILED"
  printf '%s: %s\n' "${title}" "${msg}" >&2
  command -v termux-notification >/dev/null 2>&1 \
    && { termux-notification --title "${title}" --content "${msg}" >/dev/null 2>&1 || true; }
  command -v termux-toast >/dev/null 2>&1 \
    && { termux-toast "${msg}" >/dev/null 2>&1 || true; }
  # Explicit return 0: under `set -e`, a FUNCTION's own exit status is the
  # status of its last command, and calling a function bare (as every caller
  # here does) is NOT exempt the way `cmdA && cmdB` is inline (cmdA failing
  # there never trips -e because cmdB simply never runs) -- if termux-toast
  # is absent, the `command -v termux-toast && {...}` line above IS this
  # function's last command and evaluates nonzero, and that WOULD kill the
  # script right here instead of reaching the caller's actual exit code.
  # Notification delivery is always best-effort; only the exit code below
  # (site-deploy.sh's own) is allowed to end the script.
  return 0
}

# _dialog_text_field JSON — extract termux-dialog's "text" field WITHOUT
# python3: python3 is guaranteed inside the proot-distro userland this repo
# manages, but NOT on the Termux HOST side (this hook's own execution
# context) — every existing host-side Termux-integration check in this repo
# (scripts/ops/doctor.sh:111-116) uses plain `command -v` + shell text tools
# rather than assuming a host Python interpreter, so this follows the same
# convention. Deliberately tolerant of an unparseable/escaped value: it just
# fails SITE_SUB_RE below and is rejected — this never needs to be a fully
# correct JSON unescaper, only good enough for a DNS-label site name.
_dialog_text_field() {
  local raw
  raw="$(printf '%s' "$1" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p')"
  # Keep only the first line (defensive; a valid single-object JSON reply
  # never has more than one) without piping through `head`, which would risk
  # a SIGPIPE on the sed side under `set -o pipefail`.
  printf '%s' "${raw%%$'\n'*}"
}

case "${SHARED_PATH}" in
  *.[zZ][iI][pP])
    : # fall through to the deploy flow below
    ;;
  *)
    # Preserve the hook's normal, pre-existing purpose for every non-zip file.
    exec "${EDITOR:-nano}" "${SHARED_PATH}"
    ;;
esac

# ── deploy flow (a shared .zip) ──────────────────────────────────────────────
SITE=""
if command -v termux-dialog >/dev/null 2>&1; then
  # termux-dialog's real CLI takes the widget type as its first positional
  # arg ("text" here) — the ground-truth verification behind this hook's
  # design (SPEC-DIFFERENTIATORS.md §7.3/§16-EXT-4/7) confirmed the primitive
  # but not this exact invocation string, so this uses termux-dialog's actual
  # documented syntax rather than guessing.
  if command -v timeout >/dev/null 2>&1; then
    DIALOG_JSON="$(timeout 60 termux-dialog text -t "Deploy site name" 2>/dev/null || true)"
  else
    # `timeout` (coreutils) is not independently verified as guaranteed in
    # Termux's minimal bootstrap, unlike sed/grep — degrade gracefully rather
    # than assume it.
    DIALOG_JSON="$(termux-dialog text -t "Deploy site name" 2>/dev/null || true)"
  fi
  SITE="$(_dialog_text_field "${DIALOG_JSON}")"
else
  # The hook runs in a real interactive Termux session (header above), so a
  # plain terminal prompt is a legitimate fallback, not a hack.
  read -r -p "Deploy site name: " SITE || SITE=""
fi

if [ -z "${SITE}" ]; then
  # Empty/cancelled -- exit 0 quietly. A deliberate cancel is not an error.
  exit 0
fi

if ! [[ ${SITE} =~ ${SITE_SUB_RE} ]]; then
  _report failure "invalid site name '${SITE}' (lowercase letters/digits/hyphen, 1..63 chars) -- deploy not attempted"
  exit 1
fi

DEPLOY_SCRIPT="${POCKET_ROOT}/scripts/sites/site-deploy.sh"
if [ ! -f "${DEPLOY_SCRIPT}" ]; then
  _report failure "pocket-homeserver not found at ${POCKET_ROOT} -- re-run scripts/apps/sites.sh (ENABLE_SITES_SHARE_DEPLOY=true) to reinstall this hook"
  exit 1
fi

rc=0
bash "${DEPLOY_SCRIPT}" "${SITE}" "${SHARED_PATH}" || rc=$?
if [ "${rc}" -eq 0 ]; then
  _report success "${SITE} deployed from ${SHARED_PATH}"
else
  _report failure "deploy of '${SITE}' from ${SHARED_PATH} exited ${rc} -- see the terminal output above"
  exit "${rc}"
fi
