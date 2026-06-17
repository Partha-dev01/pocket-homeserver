#!/usr/bin/env bash
#
# leak-scan.sh — guard against committing secrets or deployment-specific data
# to this public repository.
#
# It scans tracked (or staged) files for two classes of problem:
#   1. Generic secrets   — private keys, API tokens, passwords, public IPs.
#   2. A local deny-list — your own domain, storage IDs, usernames, etc., read
#      from a gitignored `.leak-deny` file (one `grep -E` pattern per line;
#      blank lines and `#` comments are ignored).
#
# The deny-list lives ONLY on your machine: `.leak-deny` is gitignored, so the
# strings you are protecting never enter the repository — not even in here.
#
# Usage:
#   tools/leak-scan.sh            # scan all tracked files
#   tools/leak-scan.sh --staged   # scan only staged changes (for a pre-commit hook)
#
# Exit status: 0 = clean, 1 = potential leak found, 2 = usage/setup error.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "leak-scan: not inside a git repository" >&2; exit 2; }
cd "$repo_root"

mode="tracked"
case "${1:-}" in
  "")       mode="tracked" ;;
  --staged) mode="staged" ;;
  *) echo "usage: leak-scan.sh [--staged]" >&2; exit 2 ;;
esac

declare -a files
if [ "$mode" = "staged" ]; then
  mapfile -d '' files < <(git diff --cached --name-only --diff-filter=ACM -z)
else
  mapfile -d '' files < <(git ls-files -z)
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "leak-scan: no files to scan"; exit 0
fi

found=0
report() {   # $1=label  $2=pattern  $3=hits
  found=1
  printf '\n-- %s  /%s/\n' "$1" "$2"
  printf '%s\n' "$3" | sed 's/^/   /'
}

# 1) Always-real secret patterns (private keys + provider tokens).
generic_patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'AKIA[0-9A-Z]{16}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
)
for pat in "${generic_patterns[@]}"; do
  hits="$(grep -nIE -- "$pat" "${files[@]}" 2>/dev/null || true)"
  [ -n "$hits" ] && report "generic" "$pat" "$hits"
done

# 1b) A password/secret/token assigned to a LITERAL (an embedded secret).
# Quoted values are already excluded by the value class (it stops at a quote), so
# `x = "literal"` does not match. We additionally drop values that are a code
# expression — a function/method call such as `token = resp.get(...)` or
# `access_token = secrets.token_urlsafe(32)` — because those read/derive the value
# in source rather than hardcoding it. A literal like `TOKEN=abc123` is NOT a call
# and is still reported.
secret_assign='(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]"'\''#]+'
# benign: RHS is an identifier with optional attribute access, ending in a call '('.
benign_call='[=:][[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\('
# benign: RHS is plainly NOT a hardcoded literal — a shell/template variable ($X,
# ${X}), an escaped quote (\"...), markup (a <tag>, e.g. HTML like `password:</p>`),
# or a doc placeholder (… / ...). A real embedded secret is a literal alphanumeric
# value, which begins with none of these and is still reported.
benign_value='[=:][[:space:]]*(\$|\\|<|…|\.\.\.)'
sec_hits="$(grep -nIE -- "$secret_assign" "${files[@]}" 2>/dev/null \
  | grep -vE -- "$benign_call" | grep -vE -- "$benign_value" || true)"
[ -n "$sec_hits" ] && report "generic" "$secret_assign" "$sec_hits"

# 2) Public IPv4 addresses (loopback / private / link-local are not leaks).
ip_pat='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
# loopback / unspecified / private / link-local / broadcast, plus well-known
# PUBLIC DNS resolvers (universal constants, not anyone's infrastructure).
benign='(127\.[0-9.]+|0\.0\.0\.0|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|255\.[0-9.]+|169\.254\.[0-9.]+|1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9)'
ip_hits="$(grep -nIE -- "$ip_pat" "${files[@]}" 2>/dev/null | grep -vE -- "$benign" || true)"
[ -n "$ip_hits" ] && report "public-ip" "$ip_pat" "$ip_hits"

# 3) Local deny-list (gitignored; deployment-specific strings).
if [ -f .leak-deny ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    hits="$(grep -nIE -- "$line" "${files[@]}" 2>/dev/null || true)"
    [ -n "$hits" ] && report "deny-list" "$line" "$hits"
  done < .leak-deny
fi

if [ "$found" -ne 0 ]; then
  printf '\nleak-scan: POTENTIAL LEAK(S) FOUND — review the above before committing/pushing.\n' >&2
  exit 1
fi
echo "leak-scan: clean (${mode}, ${#files[@]} files)."
exit 0
