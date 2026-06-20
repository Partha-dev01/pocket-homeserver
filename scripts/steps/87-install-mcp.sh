#!/usr/bin/env bash
#
# steps/87-install-mcp.sh — install + (HTTP mode) supervise the OPTIONAL MCP
# (Model Context Protocol) server, so an MCP client (Claude Desktop, Claude Code,
# the claude.ai connector, or any other MCP host) can observe and operate the
# stack through a small, audited tool set. The server is a thin protocol adapter:
# it adds NO new privileged operation — every mutating tool shells out to an
# already-vetted scripts/ops/* script and every read tool reuses the same probes
# the admin panel runs. See docs/MCP_SERVER_SPEC.md (design) + docs/MCP.md (how-to).
#
# It is a core step that SELF-GATES on ENABLE_MCP (install.sh runs it
# unconditionally; it no-ops unless you opt in), so a default install never
# touches it. ENABLE_MCP defaults to false.
#
# It runs TERMUX-NATIVE (NOT inside the proot userland), for the same reason the
# admin panel does: its operate/danger tools orchestrate the HOST (proot-distro
# restarts via scripts/ops/*, the supervisor pidfiles under ${POCKET_STATE_DIR},
# pgrep of host processes). None of that is possible from inside the userland.
#
# Two transports, selected by MCP_TRANSPORT (stdio | http | both):
#   * stdio (default, recommended): the MCP client spawns the server over SSH;
#     the SSH/Cloudflare-Access channel IS the authentication. NOTHING is
#     published. We install a `pocket-mcp` launcher on the Termux PATH; the client
#     runs it on demand (`ssh phone pocket-mcp`), so it is NOT supervised.
#   * http (optional remote): a Caddy vhost mcp.${DOMAIN} -> the loopback ASGI
#     server (the official `mcp` SDK's streamable_http_app via uvicorn). Fail-
#     closed behind THREE gates: Caddy Cf-Access-Jwt presence (this vhost), the
#     in-process RS256 JWT validation, and a 0600 bearer credential. Supervised
#     like any other service (records its .cmd so start-stack.sh revives it).
#
# What it does (idempotent — safe to re-run):
#   1. ensures a Termux Python venv at ~/pocket-mcp/.venv with the pinned `mcp`
#      SDK (+ uvicorn) from scripts/mcp/requirements.txt, then a FAIL-LOUD
#      `python -c "import mcp"` check (pydantic-core may need a build on Termux),
#   2. copies scripts/mcp/pocket-mcp.py -> ~/pocket-mcp/pocket-mcp.py + parse-checks,
#   3. (stdio | both) installs a `pocket-mcp` launcher on the Termux PATH,
#   4. (http  | both) generates a 0600 bearer credential (off argv), renders the
#      mcp.caddy vhost + validates it fail-closed, writes the http launcher, and
#      supervises the ASGI server,
#   5. prints the start-stack.sh --restart hint (we never restart Caddy here).
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env

# ── Self-gate: only run when explicitly enabled (default off) ────────────────
if [ "${ENABLE_MCP:-false}" != "true" ]; then
  ok "MCP server disabled (ENABLE_MCP != true) — skipping (this is the default)"
  exit 0
fi

require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

# ── Transport selection (decides which halves of this step run) ──────────────
MCP_TRANSPORT="${MCP_TRANSPORT:-stdio}"
case "${MCP_TRANSPORT}" in
  stdio|http|both) : ;;
  *) die "MCP_TRANSPORT must be one of: stdio | http | both (got '${MCP_TRANSPORT}')" ;;
esac
want_stdio=0; want_http=0
case "${MCP_TRANSPORT}" in
  stdio) want_stdio=1 ;;
  http)  want_http=1 ;;
  both)  want_stdio=1; want_http=1 ;;
esac
# The HTTP transport publishes a vhost, so it needs a real domain; stdio does not.
if [ "${want_http}" -eq 1 ]; then
  require_var DOMAIN      "your public domain, e.g. example.com"
  require_cmd proot-distro    # for writing + validating the Caddy vhost in the userland
fi

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Config ───────────────────────────────────────────────────────────────────
MCP_DIR="${HOME}/pocket-mcp"                      # Termux-native install dir
MCP_VENV="${MCP_DIR}/.venv"
MCP_SRC="${POCKET_ROOT}/scripts/mcp/pocket-mcp.py"
MCP_REQS="${POCKET_ROOT}/scripts/mcp/requirements.txt"
MCP_CADDY_TMPL="${POCKET_ROOT}/scripts/mcp/mcp.caddy.tmpl"

MCP_HTTP_HOST="${MCP_HTTP_HOST:-mcp}"             # subdomain LABEL -> mcp.${DOMAIN}
MCP_HTTP_PORT="${MCP_HTTP_PORT:-9120}"           # loopback bind (HTTP mode); Caddy fronts the edge
SECRETS_DIR="${DATA_DIR}/secrets"
# 0600 bearer credential (HTTP mode). NOTE: do NOT inline a default with a literal
# secret — this is a PATH, generated below if absent, never echoed/argv'd.
BEARER_FILE="${MCP_BEARER_TOKEN_FILE:-${SECRETS_DIR}/mcp-bearer.cred}"

[ -f "${MCP_SRC}" ]  || die "MCP server source missing: ${MCP_SRC} — the mcp module was not shipped"
[ -f "${MCP_REQS}" ] || die "MCP requirements missing: ${MCP_REQS} — the mcp module was not shipped"
mkdir -p "${MCP_DIR}" "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# ── 1. Python venv with the pinned MCP SDK (Termux-native) + fail-loud import ──
# A venv keeps the SDK's deps (pydantic-core, uvicorn, anyio, starlette) off the
# system Python. Versions are PINNED in requirements.txt (==); pip still verifies
# each wheel against PyPI. The SDK pulls pydantic-core (a compiled Rust extension);
# on Termux/aarch64 that may need a prebuilt wheel or a local Rust build, so the
# import check below is FAIL-LOUD with a pointer to the on-device build notes.
if [ ! -x "${MCP_VENV}/bin/python" ]; then
  say "creating the MCP venv at ${MCP_VENV}"
  python3 -m venv "${MCP_VENV}" || die "failed to create the MCP venv (is python3-venv installed?)"
fi
say "installing the MCP SDK into the venv from ${MCP_REQS} (first run downloads it)"
"${MCP_VENV}/bin/pip" install --upgrade pip wheel >/dev/null 2>&1 || warn "pip self-upgrade reported a problem (continuing)"
"${MCP_VENV}/bin/pip" install -r "${MCP_REQS}" >/dev/null \
  || die "could not install the MCP SDK into the venv from ${MCP_REQS} (on Termux/aarch64 pydantic-core may need a build — see docs/MCP.md)"
# FAIL LOUD: the SDK MUST import, or every later transport is dead. This is the
# single most likely failure on a phone (the pydantic-core / uvicorn compiled deps).
"${MCP_VENV}/bin/python" -c 'import mcp' \
  || die "the 'mcp' SDK failed to import in the venv (likely a pydantic-core build issue on Termux/aarch64); see docs/MCP.md for the on-device build steps"
ok "MCP venv ready ($("${MCP_VENV}/bin/python" -c 'import importlib.metadata as m; print("mcp", m.version("mcp"))' 2>/dev/null))"

# ── 2. Copy the server into place + fail-closed parse check ──────────────────
install -m 644 "${MCP_SRC}" "${MCP_DIR}/pocket-mcp.py" || die "failed to copy the MCP server to ${MCP_DIR}/pocket-mcp.py"
"${MCP_VENV}/bin/python" -c "import ast,sys; ast.parse(open('${MCP_DIR}/pocket-mcp.py').read())" \
  || die "the copied MCP server failed to parse under the venv python"
ok "MCP server installed at ${MCP_DIR}/pocket-mcp.py"

# ── Shared env contract baked into both launchers ─────────────────────────────
# Only NON-SECRET config is exported here (known at install time). The bearer
# credential is NEVER exported on a launcher line: the http launcher reads it from
# the 0600 file at runtime (off argv). The ops scripts the server runs re-read
# .env themselves. The exported keys mirror what the server reads (spec §11).
# pocket-mcp.py ALSO self-sources ${POCKET_ROOT}/.env (the real process env wins),
# so any key not exported here is still picked up — these exports just pin the
# resolved paths (POCKET_STATE_DIR/LOG_DIR/BACKUP_DIR are common.sh defaults, not
# present in .env) and the tier flags the server gates registration on.
_emit_env() {
  cat <<ENVBLOCK
export POCKET_ROOT='${POCKET_ROOT}'
export DATA_DIR='${DATA_DIR}'
export POCKET_STATE_DIR='${POCKET_STATE_DIR}'
export POCKET_LOG_DIR='${POCKET_LOG_DIR}'
export BACKUP_DIR='${BACKUP_DIR}'
export DOMAIN='${DOMAIN:-}'
export MATRIX_SERVER_NAME='${MATRIX_SERVER_NAME:-${DOMAIN:-}}'
export CADDY_BIND='${CADDY_BIND}'
export CADDY_PORT='${CADDY_PORT}'
export MCP_ALLOW_OPERATE='${MCP_ALLOW_OPERATE:-false}'
export MCP_ALLOW_DANGER='${MCP_ALLOW_DANGER:-false}'
export MCP_LOG_REDACT='${MCP_LOG_REDACT:-true}'
export MCP_ALLOWED_LOGS='${MCP_ALLOWED_LOGS:-}'
export MCP_RATE_LIMIT='${MCP_RATE_LIMIT:-60/min}'
# Which subsystems the read tier may surface (no secrets — just the gates).
export ENABLE_HONEYPOT='${ENABLE_HONEYPOT:-false}'
export ENABLE_AUTH_GATEWAY='${ENABLE_AUTH_GATEWAY:-false}'
export ENABLE_ADMIN='${ENABLE_ADMIN:-true}'
export ENABLE_BACKUP_DAEMON='${ENABLE_BACKUP_DAEMON:-false}'
ENVBLOCK
}

# ── 3. stdio transport: a `pocket-mcp` launcher on the Termux PATH ───────────
# stdio is the recommended default. The MCP client runs `ssh phone pocket-mcp`,
# so the launcher must be resolvable on the Termux login PATH. We install it into
# $PREFIX/bin (the Termux bin dir — the same convention 75-install-boot.sh uses
# for $PREFIX). It is a FILE (not supervised): the SSH session spawns it on
# demand, and the SSH/CF-Access channel is the authentication. stdout is the
# JSON-RPC protocol channel, so the server sends ALL diagnostics to stderr — we
# must not print anything to its stdout here.
if [ "${want_stdio}" -eq 1 ]; then
  PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
  if [ -d "${PREFIX_DIR}/bin" ] && [ -w "${PREFIX_DIR}/bin" ]; then
    MCP_LAUNCHER="${PREFIX_DIR}/bin/pocket-mcp"
  else
    # Not on Termux (e.g. a laptop dry-run) or the bin dir isn't writable: fall
    # back to the install dir so the file still exists + parse-checks, and tell
    # the operator how to reach it. start-stack does NOT supervise stdio.
    MCP_LAUNCHER="${MCP_DIR}/pocket-mcp"
    warn "Termux \$PREFIX/bin not writable — writing the stdio launcher to ${MCP_LAUNCHER} instead of PATH"
  fi
  say "writing the stdio launcher → ${MCP_LAUNCHER}"
  {
    echo "#!${PREFIX:-/data/data/com.termux/files/usr}/bin/bash"
    echo "# pocket-mcp — stdio MCP launcher. Installed by steps/87-install-mcp.sh."
    echo "# An MCP client runs this over SSH (\`ssh phone pocket-mcp\`); the SSH/CF-Access"
    echo "# channel is the authentication. stdout is the JSON-RPC channel — keep it clean."
    _emit_env
    echo "export MCP_TRANSPORT=stdio"
    echo "cd '${MCP_DIR}' || exit 1"
    echo "exec '${MCP_VENV}/bin/python' '${MCP_DIR}/pocket-mcp.py'"
  } > "${MCP_LAUNCHER}"
  chmod 755 "${MCP_LAUNCHER}"
  ok "stdio launcher installed at ${MCP_LAUNCHER}"
fi

# ── 4. http transport: bearer credential + vhost + supervised ASGI server ────
if [ "${want_http}" -eq 1 ]; then
  [ -f "${MCP_CADDY_TMPL}" ] || die "MCP Caddy template missing: ${MCP_CADDY_TMPL} — the mcp module was not shipped"
  in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — run scripts/install.sh first"

  # ── 4a. Bearer credential (0600; generated once, reused on re-run) ─────────
  # Gate 3 of the HTTP fail-closed chain (spec §6.2/§10): a high-entropy bearer
  # the server checks with hmac.compare_digest, so a misconfigured Cloudflare
  # Access policy alone cannot open the server. Generated OFF argv (openssl writes
  # straight to the 0600 file); NEVER echoed, NEVER returned by any tool.
  # The server reads this credential from MCP_BEARER_TOKEN_FILE (the FILE, not an
  # env value) once at startup and compares it with hmac.compare_digest.
  if [ -s "${BEARER_FILE}" ]; then
    say "reusing existing MCP bearer credential at ${BEARER_FILE}"
  else
    say "generating the MCP bearer credential → ${BEARER_FILE} (0600)"
    ( umask 077; openssl rand -base64 48 | tr -d '\n' > "${BEARER_FILE}" ) \
      || die "failed to generate the MCP bearer credential at ${BEARER_FILE}"
    chmod 600 "${BEARER_FILE}" 2>/dev/null || true
  fi
  [ -s "${BEARER_FILE}" ] || die "MCP bearer credential is missing/empty at ${BEARER_FILE}"

  # ── 4b. Render the Caddy vhost from the template + validate fail-closed ─────
  # Substitute the same way 86-install-webmail.sh does (sed __TOKENS__), pipe into
  # the userland, then `caddy validate` the FULL config. We do NOT restart Caddy
  # here — we print the start-stack.sh --restart hint at the end.
  say "writing the Caddy vhost → /etc/caddy/apps/mcp.caddy"
  sed -e "s|__DOMAIN__|${DOMAIN}|g" \
      -e "s|__MCP_HOST__|${MCP_HTTP_HOST}|g" \
      -e "s|__CADDY_BIND__|${CADDY_BIND}|g" \
      -e "s|__CADDY_PORT__|${CADDY_PORT}|g" \
      -e "s|__MCP_HTTP_PORT__|${MCP_HTTP_PORT}|g" \
      "${MCP_CADDY_TMPL}" \
    | proot-distro login debian -- bash -lc 'mkdir -p /etc/caddy/apps && cat > /etc/caddy/apps/mcp.caddy' \
    || die "failed to write /etc/caddy/apps/mcp.caddy"
  ok "wrote /etc/caddy/apps/mcp.caddy"

  say "validating the Caddyfile inside the userland"
  in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
    || die "caddy validate FAILED — refusing to leave a broken vhost in place (fix /etc/caddy/apps/mcp.caddy)"
  ok "Caddyfile still valid with the MCP vhost added"

  # ── 4c. Write the http launcher (Termux-native; sources env + bearer off argv) ─
  # Kept as a FILE so the supervise argv stays a single element (the .cmd rule:
  # one line per argv element — `bash <run-mcp-http.sh>`). The launcher exports the
  # non-secret env, then exports the bearer FILE PATH (not the value) so the server
  # reads the credential itself off argv. The CF-Access trio is exported for the
  # in-process RS256 JWT validation (gate 2). The server binds the loopback; Caddy
  # fronts the public TLS edge.
  # Entrypoint: pocket-mcp.py owns its own uvicorn.run() under MCP_TRANSPORT=http
  # (it builds streamable_http_app() wrapped in the fail-closed auth gate), so the
  # `exec python pocket-mcp.py` below is correct — no bare uvicorn invocation.
  say "writing the http launcher → ${MCP_DIR}/run-mcp-http.sh"
  {
    echo "#!${PREFIX:-/data/data/com.termux/files/usr}/bin/bash"
    echo "# Runs the MCP server (HTTP transport) TERMUX-NATIVE; started + kept alive"
    echo "# by steps/87-install-mcp.sh (supervised via start-stack.sh's .cmd glob)."
    echo "# Binds ${CADDY_BIND}:${MCP_HTTP_PORT}; Caddy fronts the public TLS edge."
    _emit_env
    echo "export MCP_TRANSPORT=http"
    echo "export MCP_HTTP_HOST='${MCP_HTTP_HOST}'"
    echo "export MCP_HTTP_BIND='${CADDY_BIND}'"
    echo "export MCP_HTTP_PORT='${MCP_HTTP_PORT}'"
    echo "# Bearer credential: the FILE PATH is exported (never the value) — the server"
    echo "# reads it itself and compares with hmac.compare_digest."
    echo "export MCP_BEARER_TOKEN_FILE='${BEARER_FILE}'"
    echo "# Optional in-process Cloudflare Access JWT validation (gate 2). Reuses the"
    echo "# admin panel's keys; empty CF_ACCESS_TEAM_DOMAIN disables it (defense in depth)."
    echo "export CF_ACCESS_MODE='${CF_ACCESS_MODE:-log}'"
    echo "export CF_ACCESS_TEAM_DOMAIN='${CF_ACCESS_TEAM_DOMAIN:-}'"
    echo "export CF_ACCESS_AUD='${CF_ACCESS_AUD:-}'"
    echo "cd '${MCP_DIR}' || exit 1"
    echo "exec '${MCP_VENV}/bin/python' '${MCP_DIR}/pocket-mcp.py'"
  } > "${MCP_DIR}/run-mcp-http.sh"
  chmod 700 "${MCP_DIR}/run-mcp-http.sh"
  ok "wrote the http launcher"

  # ── 4d. Supervise the ASGI server (Termux-native) + health-check ───────────
  # Records ${POCKET_STATE_DIR}/mcp.cmd (single argv element: bash <run-mcp-http.sh>)
  # so start-stack.sh re-supervises it on every bring-up and ops/restart.sh can
  # restart it. The .cmd one-line-per-argv rule is satisfied (the launcher is a file).
  supervise mcp -- bash "${MCP_DIR}/run-mcp-http.sh"

  say "waiting for the MCP HTTP server to listen on ${CADDY_BIND}:${MCP_HTTP_PORT}"
  mcp_up=0
  for _ in $(seq 1 20); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('${CADDY_BIND}',${MCP_HTTP_PORT}))==0 else 1)" >/dev/null 2>&1; then
      mcp_up=1; break
    fi
    sleep 1
  done
  [ "${mcp_up}" -eq 1 ] && ok "MCP HTTP server listening on ${CADDY_BIND}:${MCP_HTTP_PORT}" \
    || warn "MCP HTTP server not listening yet on ${CADDY_BIND}:${MCP_HTTP_PORT} — check ${POCKET_LOG_DIR}/mcp.log"
fi

# ── Closing notes ─────────────────────────────────────────────────────────────
echo
ok "MCP server installed (transport: ${MCP_TRANSPORT})"
if [ "${want_stdio}" -eq 1 ]; then
  say "stdio (recommended): point your MCP client at it over SSH, e.g. in .mcp.json:"
  say '    { "mcpServers": { "pocket": { "command": "ssh", "args": ["phone", "pocket-mcp"] } } }'
  say "  (the SSH/Cloudflare-Access channel is the authentication; nothing is published)."
fi
say "Tool tiers: read tools are always on; the OPERATE tier needs MCP_ALLOW_OPERATE=true,"
say "  and the DANGER tier (panic) needs MCP_ALLOW_DANGER=true AND a per-call typed confirm."
if [ "${want_http}" -eq 1 ]; then
  echo
  say "Manual Cloudflare steps for the HTTP transport (in the dashboard — NOT done here):"
  say "  1. Tunnel public hostname:  ${MCP_HTTP_HOST}.${DOMAIN}  ->  http://localhost:${CADDY_PORT}"
  say "  2. Add a Cloudflare Access policy protecting ${MCP_HTTP_HOST}.${DOMAIN} (only your identities)."
  say "  The 0600 bearer credential is at ${BEARER_FILE} (set it in your MCP client; never echoed here)."
  say "  If the core stack is already running, pick up the new vhost with:"
  say "     bash ${POCKET_ROOT}/scripts/start-stack.sh --restart"
  say "  (brief ingress outage while cloudflared cycles)."
fi

# NOTE: no explicit mark_done here — install.sh's run_step marks `step-mcp` on
# success (gated by set -e), exactly like every other step. Matching the siblings
# keeps a single source of truth for the resumable-install marker.

# Generalized from a working deployment; review before running.
