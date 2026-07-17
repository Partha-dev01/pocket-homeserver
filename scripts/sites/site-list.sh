#!/usr/bin/env bash
#
# sites/site-list.sh — read-only registry inspection (SPEC-SITES-PIPELINE §5,
# §6). Read the spec first; this header only orients you.
#
# Usage:
#   site-list.sh [--json] [--rebuild]
#
#   (no flags)   human-readable table: SITE / BUILD / ACTIVE / RELEASES /
#                BYTES / URL / UPDATED, one row per registered site.
#   --json       dump .registry.json verbatim (for the panel/MCP — a stable
#                machine-readable contract, §5's schema exactly).
#   --rebuild    reconstruct .registry.json FROM the on-disk release tree
#                before listing/dumping — the registry is derived state, so
#                this is the self-healing path after a restore or any
#                out-of-band filesystem edit (§5).
#
# This script takes NO user-derived argv beyond the two flags above — there is
# no site name to validate here, it only ever reads.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sites.sh"

load_env
require_var DOMAIN "your public domain — used by --rebuild to derive each site's URL"
require_cmd python3

JSON=0
REBUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    *) die "unknown argument: $1 (usage: site-list.sh [--json] [--rebuild])" ;;
  esac
done

sites_root_init

if [ "${REBUILD}" = 1 ]; then
  say "rebuilding the registry from the on-disk release tree at ${SITES_ROOT}"
  registry_rebuild
  ok "registry rebuilt: ${REGISTRY}"
fi

if [ "${JSON}" = 1 ]; then
  cat "${REGISTRY}"
  exit 0
fi

# Human table — plain python (no jq, matching every other registry op in this
# module) so column widths line up regardless of how many sites exist.
python3 - "${REGISTRY}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        reg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    reg = {"version": 1, "sites": {}}

sites = reg.get("sites", {})
if not sites:
    print("(no sites deployed yet)")
    sys.exit(0)

rows = []
for name, s in sorted(sites.items()):
    rows.append((
        name,
        s.get("build", "none"),
        s.get("active_release", "") or "-",
        str(len(s.get("releases", []))),
        f"{s.get('bytes', 0):,}",
        s.get("url", ""),
        s.get("updated", ""),
    ))

headers = ("SITE", "BUILD", "ACTIVE", "RELEASES", "BYTES", "URL", "UPDATED")
widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(headers)]


def fmt(row):
    return "  ".join(c.ljust(w) for c, w in zip(row, widths))


print(fmt(headers))
print(fmt(tuple("-" * w for w in widths)))
for r in rows:
    print(fmt(r))
PY
