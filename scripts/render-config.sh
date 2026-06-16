#!/usr/bin/env bash
#
# render-config.sh — render the config templates in config/*.tmpl into
# config/rendered/ by substituting the values from .env.
#
# Usage: scripts/render-config.sh [OUT_DIR]   (default: config/rendered)
#
# Substitutes only a fixed, known set of ${VARS}, so Caddy's own `{...}`
# placeholders are left untouched. Values must not contain a literal `|`.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

load_env
require_var DOMAIN "your apex domain (DNS on Cloudflare)"
: "${MATRIX_SERVER_NAME:=$DOMAIN}"

out="${1:-$POCKET_ROOT/config/rendered}"
mkdir -p "$out"

render() {   # render SRC DST
  local src="$1" dst="$2"
  [ -f "$src" ] || die "template not found: $src"
  sed \
    -e "s|\${DOMAIN}|${DOMAIN}|g" \
    -e "s|\${MATRIX_SERVER_NAME}|${MATRIX_SERVER_NAME}|g" \
    -e "s|\${CADDY_BIND}|${CADDY_BIND}|g" \
    -e "s|\${CADDY_PORT}|${CADDY_PORT}|g" \
    -e "s|\${DATA_DIR}|${DATA_DIR:-}|g" \
    "$src" > "$dst"
  ok "rendered $(basename "$dst") -> $dst"
}

render "$POCKET_ROOT/config/Caddyfile.tmpl"      "$out/Caddyfile"
render "$POCKET_ROOT/config/conduwuit.toml.tmpl" "$out/conduwuit.toml"
say "config rendered into $out"
