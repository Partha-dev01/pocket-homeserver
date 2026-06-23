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
  # A JSON Web Token (header.payload — both base64url segments start "eyJ", i.e.
  # base64 of '{"'). Catches CF tunnel/Access tokens, the Forgejo INTERNAL_TOKEN,
  # OIDC/access tokens, etc. — the high-value shape a committed .env/.env.bak holds.
  # Highly distinctive (an "eyJ...eyJ..." pair is never normal source/prose).
  'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{6,}'
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
# benign: the value is a literal BOOLEAN/placeholder word (true/false/none/yes/no/
# on/off/0/1/enabled/disabled) followed by a non-identifier char or end — i.e. a CLI
# flag or config toggle like a `--must-change-password` set to false, never an embedded
# secret (a real secret value is never the bare word "false"). A value that merely
# STARTS with a boolean word (a token whose text begins "false…") is NOT excluded —
# the boolean must be the WHOLE value token.
benign_bool='[=:][[:space:]]*(true|false|none|null|yes|no|on|off|0|1|enabled|disabled)([^[:alnum:]_]|$)'
sec_hits="$(grep -nIE -- "$secret_assign" "${files[@]}" 2>/dev/null \
  | grep -vE -- "$benign_call" | grep -vE -- "$benign_value" | grep -vE -- "$benign_bool" || true)"
[ -n "$sec_hits" ] && report "generic" "$secret_assign" "$sec_hits"

# NOTE on the committed-.env class (the .env.bak-*/.env.tmp.* leak the audit flagged):
# the PRIMARY guard is .gitignore (those files can no longer be added). A broad
# "UPPERCASE_SECRET_NAME=<literal>" rule here was evaluated and REJECTED: the tree
# legitimately contains many such lines that are env-reads (X = os.environ["X"]),
# template placeholders (REPLACE_ME, your_token, __OIDC_TOKEN_URL__, ci-dummy-*) and
# secret-FILE paths — separating those from a real secret needs an entropy heuristic
# or a sprawling placeholder allowlist that would itself mask leaks. The JWT generic
# pattern above is the high-value, zero-false-positive backstop for a committed token.

# 2) Public IPv4 addresses (loopback / private / link-local are not leaks).
ip_pat='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
# Non-public ranges (never a leak): loopback / unspecified / private / link-local /
# broadcast.
benign_private='127\.[0-9.]+|0\.0\.0\.0|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|255\.[0-9.]+|169\.254\.[0-9.]+'
# Universal PUBLIC constants — not anyone's infrastructure:
#   * well-known public DNS resolvers,
#   * RFC 5737 documentation ranges (TEST-NET-1/2/3 — reserved for docs/examples,
#     never routed; the correct choice for example IPs in our docs), and
#   * Cloudflare's PUBLISHED edge ranges (https://www.cloudflare.com/ips/ —
#     identical for every Cloudflare user; the honeypot safelists them so it can
#     never ban its own tunnel, so they legitimately appear in the source).
benign_dns='1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9'
benign_doc='192\.0\.2\.[0-9.]+|198\.51\.100\.[0-9.]+|203\.0\.113\.[0-9.]+'
benign_cloudflare='173\.245\.48\.0|103\.21\.244\.0|103\.22\.200\.0|103\.31\.4\.0|141\.101\.64\.0|108\.162\.192\.0|190\.93\.240\.0|188\.114\.96\.0|197\.234\.240\.0|198\.41\.128\.0|162\.158\.0\.0|104\.16\.0\.0|104\.24\.0\.0|172\.64\.0\.0|131\.0\.72\.0'
# Pinned upstream software VERSIONS that happen to be four dot-separated numbers
# (so they trip the IPv4 regex) — these are version strings in config/versions.env,
# not addresses. Exact-match only, so a *new* 4-component version still gets flagged
# for review on bump. Currently: Kavita (0.9.0.2).
benign_versions='0\.9\.0\.2'
benign="(${benign_private}|${benign_dns}|${benign_doc}|${benign_cloudflare}|${benign_versions})"
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
