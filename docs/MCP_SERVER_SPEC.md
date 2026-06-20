# MCP Server — Design Specification

> **Status:** DRAFT / proposed — **not yet implemented.**
> **Target release:** v0.3.0 (after operator approval of the open decisions in §13).
> This document is a design RFC. No code ships until the pivotal decisions are locked.

## 1. Summary

Add an optional **Model Context Protocol (MCP)** server to pocket-homeserver so an MCP
client (Claude Desktop, Claude Code, the claude.ai web connector, or any other MCP host)
can observe and operate the stack through a small, audited set of tools — "show me the
stack status", "tail the Caddy log", "restart the linkding service", "back up the Matrix
database now".

The server is a **thin protocol adapter**. It introduces **zero new privileged
operations**: every mutating tool shells out to an already-vetted `scripts/ops/*` script,
and every read tool reuses the same probes the admin panel already runs. Its security
posture is identical to the existing admin panel danger-zone and the operator admin bot.

Like every other optional subsystem in this repo, it is **`ENABLE_MCP=false` by default**,
fully env-driven, and ships with no operator-specific values.

## 2. Motivation

The stack already has three operator surfaces: the web admin panel (`admin/app.py`), the
TUI (`pocket.sh`), and the optional Matrix admin bot (`scripts/adminbot/`). All three
wrap the same `scripts/ops/*` scripts. MCP adds a fourth surface aimed specifically at
**LLM agents**: it lets an operator drive their server from a conversational client
without exposing a shell, with structured tool schemas the model can reason about, and
with the same allowlist/audit/fail-closed guarantees as the existing surfaces.

This is a natural fit for a single-operator phone server: the operator already reaches the
device over SSH (Cloudflare Access OTP + key), so an MCP server invoked over that same SSH
channel needs **no new authentication** and no new public attack surface.

## 3. Goals and non-goals

**Goals**

- Expose a curated, schema-typed tool set over MCP, tiered by risk (read / operate / danger).
- Reuse the existing `scripts/ops/*` + `scripts/bootstrap/*` surface verbatim — add no new
  privileged code paths.
- Work out of the box over **stdio-over-SSH** for the single-operator case, with no extra auth.
- Offer an **optional remote HTTP transport** that is fail-closed behind Cloudflare Access,
  reusing the exact pattern the webmail-admin vhost and the admin panel already use.
- Never return secrets; redact logs; audit every call.
- Built on the **official MCP Python SDK** (FastMCP) in a Termux-native venv — the same venv
  pattern the admin panel (`~/pocket-admin`) already uses.

**Non-goals**

- Not a replacement for the admin panel or TUI — it is an additional, optional surface.
- No multi-tenant / multi-user model. This is a single-operator tool.
- No free-form command execution, no arbitrary file paths, no `shell=True` — ever.
- v1 does not implement server-initiated streaming (SSE push), sampling, or elicitation;
  all tools are simple request/response. These are noted as future work in §14.

## 4. Background — what we are wrapping

The server adds no capability that does not already exist. The complete surface it adapts:

| Source | What it provides |
| --- | --- |
| `scripts/ops/status.sh`, admin `gather_stats()` / `_proc_alive()` | live stack status, per-service liveness |
| `scripts/ops/restart.sh` | re-supervise a service from its recorded `.cmd` argv |
| `scripts/ops/backup-db.sh`, `backup-all.sh` | Matrix DB / full-rootfs backups (sha256 + optional age) |
| `scripts/ops/rotate-registration-token.sh` | open registration with a fresh token |
| `scripts/ops/panic-soft.sh`, `panic-hard.sh` | kill the tunnel / kill everything (danger zone) |
| `scripts/bootstrap/mint-invite-token.sh` | mint a one-time Matrix invite token |
| admin `log_audit()` | append-only audit trail |
| `scripts/lib/common.sh` (`load_env`, defaults, pidfiles, `.cmd`) | env + service registry |
| `scripts/gateway/matrix-auth-gw.py` | (future) an existing OIDC IdP for remote OAuth |

Tools that are interactive, two-phase, or paste-driven are **intentionally excluded** from
the mutating tool set (see §8.4): `rotate-admin-password`, `rotate-tunnel-token`,
`rotate-authgw-rs`, `rotate-adminbot-token`, `rotate-all`, and `restore` (offered only as a
read-only "describe the plan" tool, never executed through MCP).

## 5. Core design principle

> **The MCP server is a dumb, well-typed front door to scripts that were already audited.**

Concretely:

1. **No new privileged logic.** Every mutating tool is `subprocess.run([ops_script, args…])`
   with a fixed argv — never a string, never `shell=True`.
2. **Closed-world arguments.** A `service` argument is validated against the set of
   currently-supervised services (read from `${POCKET_STATE_DIR}/*.cmd`) before any script
   runs. A `log` argument is validated against a fixed allowlist. There is no argument that
   can name an arbitrary path or command.
3. **Tiered + gated.** Read tools are always on (when the server is on). Operate and danger
   tools are each behind their own env flag and default off. Danger tools additionally
   require a per-call typed confirmation argument, mirroring the admin panel danger-zone.
4. **Secrets never cross the boundary.** Rotation tools return metadata only ("rotated, new
   token written to <file>"), never the secret. Log output is redacted.
5. **Audited.** Every `tools/call` is written to the same audit log the admin panel uses.

## 6. Runtime and transports

### 6.1 Runtime

- **Termux-native Python 3** (like `admin/app.py`), because operate/danger tools orchestrate
  the *host*: `proot-distro` restarts, supervisor pidfiles under `${POCKET_STATE_DIR}`, and
  `pgrep` of host processes. (The gateway runs in-proot because it has no host role; the MCP
  server, like the admin panel, must be native.)
- Sources `scripts/lib/common.sh` semantics via a small Python env loader (same keys:
  `DATA_DIR`, `POCKET_ROOT`, `POCKET_STATE_DIR`, `POCKET_LOG_DIR`, `BACKUP_DIR`, the
  `ENABLE_*` flags).
- **Dependency:** the `mcp` SDK is installed into a dedicated venv (e.g. `~/pocket-mcp`) at
  install time from a **version-pinned** `requirements.txt` (`==` pins; **not**
  `--require-hashes` — per the project's standing pip policy, frozen cross-platform hash sets
  are their own liability, so we rely on `==` pins + pip's per-wheel integrity check). The SDK
  pulls `pydantic-core` (a compiled Rust extension); on Termux this needs a prebuilt wheel or
  a local Rust build — the install step **fails loud** if the SDK cannot be imported after
  install, and the on-device build is an operator-verified step (documented in `docs/MCP.md`,
  like the BYO-llama and Maddy builds).
- `ENABLE_MCP=false` by default. In HTTP mode it is supervised like any other service and
  appears in the admin panel health list; in stdio mode it is launched on demand by the
  client (nothing to supervise).

### 6.2 Transports

Two transports, selected by `MCP_TRANSPORT` (`stdio` | `http` | `both`):

**(1) stdio-over-SSH — primary, recommended default.**

The single operator already has SSH to the phone (Cloudflare Access OTP + key). The MCP
client spawns the server over that channel; **the SSH session is the authentication**. No
port is published, no bearer credential is needed, nothing new is exposed.

```jsonc
// client config (e.g. Claude Desktop / Claude Code .mcp.json)
{
  "mcpServers": {
    "pocket": { "command": "ssh", "args": ["phone", "pocket-mcp"] }
  }
}
```

`pocket-mcp` is a tiny launcher installed by `scripts/steps/87-install-mcp.sh` that sources
the env and `exec`s the server in stdio mode. Messages are newline-delimited JSON-RPC on
stdin/stdout; all diagnostics go to stderr (never stdout — stdout is the protocol channel).

**(2) Streamable HTTP — optional remote.**

For clients that connect over the network (e.g. the claude.ai connector). Served on a
dedicated Caddy vhost `mcp.${DOMAIN}` → loopback `${CADDY_BIND}:${MCP_HTTP_PORT}`, with TLS
terminated at the Cloudflare edge (plain HTTP on the loopback, exactly like every other
vhost in the stack). The apex/subdomain does not collide — core only claims `chat.${DOMAIN}`.

This transport is **fail-closed behind Cloudflare Access**, with three independent gates:

1. **Caddy presence gate** (cheap first line, copied verbatim from `webmail-admin.caddy.tmpl`):
   ```caddy
   @no_cf_jwt not header Cf-Access-Jwt-Assertion *
   respond @no_cf_jwt "Forbidden: Cloudflare Access required" 403
   ```
   Any request that did not pass a Cloudflare Zero-Trust policy (direct-to-origin probe, or a
   published hostname with no Access policy attached) is rejected at the edge proxy.
2. **In-process RS256 JWT validation** — reuse the admin panel's `_cfa_validate()` logic
   (`CF_ACCESS_MODE` / `CF_ACCESS_TEAM_DOMAIN` / `CF_ACCESS_AUD`, JWKS fetch with kid-rotation
   refetch, issuer/exp/nbf/aud checks). The validated Access email becomes the audited caller
   identity.
3. **Bearer credential** — a 0600 credential file (`MCP_BEARER_TOKEN_FILE`, generated at
   install) checked with `hmac.compare_digest`, so a misconfigured Access policy alone cannot
   open the server.

HTTP responses are `application/json` for the request/response tool set (no SSE needed in
v1 — see §14). Session correlation uses the standard `Mcp-Session-Id` header; protocol
version is negotiated in `initialize` and echoed in the `MCP-Protocol-Version` header.

## 7. Protocol implementation

Built on the **official MCP Python SDK** (`mcp`), using its high-level **FastMCP** server.
The SDK owns the JSON-RPC 2.0 wire protocol, capability negotiation, and both transports
(`stdio` and Streamable HTTP), so our code is just **tool/resource/prompt registrations plus
the security wrapper** — we add no protocol code of our own. The SDK tracks the current MCP
revision; we pin the SDK version (`==`) so the wire behaviour is reproducible.

Tools are registered with typed signatures (the SDK derives the JSON Schema from the Python
type hints via `pydantic`). Each registration is a thin wrapper that performs the tier
check + argument allowlisting + audit, then `subprocess.run([...])` of the backing ops
script (§5). A tool that is gated off by env is simply **not registered**, so the SDK's
`tools/list` never advertises it.

Capabilities advertised: `tools`, `resources`, `prompts`. Tool-level failures are returned
as an error result (text content + `isError`), distinct from a JSON-RPC protocol error — the
SDK handles both encodings.

**Transports via the SDK:**

- **stdio:** `FastMCP(...).run("stdio")` — the SDK reads/writes newline-delimited JSON-RPC on
  stdin/stdout; all our diagnostics go to stderr.
- **Streamable HTTP:** the SDK exposes an ASGI app (`streamable_http_app()`); we serve it
  with a minimal ASGI server (e.g. `uvicorn`, pinned alongside the SDK) bound to
  `${CADDY_BIND}:${MCP_HTTP_PORT}`. The security wrapper (bearer check + optional in-process
  CF-Access JWT validation) is **ASGI middleware** in front of the MCP app; the Caddy
  `@no_cf_jwt` presence gate sits in front of that at the edge (§6.2).

The official SDK was chosen over a hand-written stdlib server (operator decision §13) for
spec conformance and lower maintenance; the cost is the `pydantic-core`/`uvicorn`
dependency, handled by the pinned venv + fail-loud import check in §6.1.

## 8. Capability model — the tool set

Tools are organized into three tiers. `tools/list` only returns the tools whose tier is
enabled, so a client never sees a tool it cannot call.

### 8.1 READ tier — always on when `ENABLE_MCP=true`

| Tool | Wraps | Returns |
| --- | --- | --- |
| `pocket_status` | `ops/status.sh` / `gather_stats()` | overall stack snapshot (services, uptime, disk, memory) |
| `pocket_health` | admin `HEALTH_PROCS` / HTTP checks | per-service up/down + the probe used |
| `pocket_list_services` | `${POCKET_STATE_DIR}/*.cmd` + pidfiles | supervised services and their liveness |
| `pocket_logs` | tail an **allowlisted** log file | last N lines, **redacted** (see §9) |
| `pocket_config` | `.env` `ENABLE_*` + non-secret keys | which subsystems are enabled (no secrets) |
| `pocket_backups_list` | `BACKUP_DIR` listing | backups present (name/size/mtime, no contents) |
| `pocket_honeypot_recent` | honeypot ledger read (only if `ENABLE_HONEYPOT`) | recent events (IPs already public attacker data) |
| `pocket_matrix_users` | Matrix admin API (read-only) | user list / count (no tokens) |
| `pocket_restore_describe` | `ops/restore.sh` dry-run / plan | the restore plan, **never executes** (see §8.4) |

### 8.2 OPERATE tier — `MCP_ALLOW_OPERATE=true`

| Tool | Wraps | Notes |
| --- | --- | --- |
| `pocket_restart_service` | `ops/restart.sh <svc>` | `<svc>` validated against the supervised set |
| `pocket_backup_db` | `ops/backup-db.sh` | stop-matrix → tar → restart; returns artifact metadata |
| `pocket_backup_all` | `ops/backup-all.sh` | full rootfs tar; returns artifact metadata |
| `pocket_mint_invite_token` | `bootstrap/mint-invite-token.sh` | returns a one-time invite token (its purpose is to be shared) |
| `pocket_rotate_registration_token` | `ops/rotate-registration-token.sh` | returns **metadata only**, never the token |

### 8.3 DANGER tier — `MCP_ALLOW_DANGER=true` **and** a per-call typed confirmation

Mirrors the admin panel danger-zone: the tool schema requires a `confirm` argument whose
value must equal a fixed phrase (e.g. the tool name) or the call is refused before anything
runs.

| Tool | Wraps |
| --- | --- |
| `pocket_panic_soft` | `ops/panic-soft.sh` (drop the tunnel — server goes dark, recoverable) |
| `pocket_panic_hard` | `ops/panic-hard.sh` (stop everything except the admin panel) |

### 8.4 Intentionally NOT exposed as mutating tools

`rotate-admin-password`, `rotate-tunnel-token` (needs an interactive paste of a new token),
`rotate-authgw-rs` (two-phase + manual env edit), `rotate-adminbot-token`, `rotate-all`,
`backup-daemon` (a supervised loop, not a one-shot), and `restore` (destructive, multi-step).
`restore` **is** exposed, but **read-only**: `pocket_restore_describe` (READ tier) runs
`restore.sh` in its dry-run/plan mode and returns the plan output **without executing**
anything (decision §13). Bootstrap creation steps (`create-admin`, `create-spaces`,
`create-announcements`) are one-time and idempotency-sensitive and are left to the TUI/CLI.

## 9. Resources and prompts

**Resources** (read-only, addressable):

- `pocket://status` — the same snapshot as `pocket_status`, as a resource.
- `pocket://config` — enabled subsystems + non-secret config.
- `pocket://docs/{name}` — a templated resource exposing this repo's `docs/*.md` so a client
  can pull the runbooks (e.g. `pocket://docs/BACKUPS`).

**Prompts** (shipped in v1, decision §13):

- `triage(service)` — a prompt scaffold that walks the model through diagnosing one service
  (check health → tail its log → suggest a restart).
- `health-report` — summarize overall stack health from `pocket_status` + `pocket_health`.

## 10. Security model

| Concern | Mitigation |
| --- | --- |
| Arbitrary command execution | fixed argv per tool; `shell=False`; no tool accepts a path or command |
| Argument injection | `service` validated against supervised set; `log` against a fixed allowlist; integers bounded |
| Secret exfiltration | rotation tools return metadata only; `pocket_logs` redacted (leak-scan-style patterns: tokens, keys, bearer values); `pocket_config` filters to `ENABLE_*` + known non-secret keys |
| Unauthorized mutation | operate + danger tiers each behind their own env flag, default off; danger needs a typed confirm |
| Remote exposure (HTTP) | three independent gates — Caddy `@no_cf_jwt` 403, in-process RS256 JWT validation, 0600 bearer credential (`compare_digest`) |
| stdio exposure | authentication is the SSH/CF-Access channel itself; nothing published |
| Abuse / runaway | per-session rate limit (reuse the gateway limiter pattern) |
| Forensics | every `tools/call` written via `log_audit()` — caller = CF-Access email (HTTP) or `"ssh"` (stdio), tool name, args (redacted), result status |
| Fail-closed | unknown tool → error; missing flag → tool not listed and call refused; any exception → error result, never a partial side effect |

**Bearer/credential hygiene:** the HTTP bearer credential is generated at install into a
0600 file under `${DATA_DIR}/secrets/`, never echoed, never on argv, never returned by any
tool — same discipline as `CF_TUNNEL_TOKEN` and the adminbot credential.

## 11. Configuration (`.env`)

All keys default to the safe/off value; the server is inert until `ENABLE_MCP=true`.

| Key | Default | Meaning |
| --- | --- | --- |
| `ENABLE_MCP` | `false` | master gate |
| `MCP_TRANSPORT` | `stdio` | `stdio` \| `http` \| `both` |
| `MCP_HTTP_HOST` | `mcp` | subdomain label → `mcp.${DOMAIN}` (HTTP mode) |
| `MCP_HTTP_PORT` | `9120` | loopback port (HTTP mode; chosen clear of 8443/9090/909x/911x/9095/8451) |
| `MCP_ALLOW_OPERATE` | `false` | enable the operate tier |
| `MCP_ALLOW_DANGER` | `false` | enable the danger tier (still needs per-call confirm) |
| `MCP_BEARER_TOKEN_FILE` | `${DATA_DIR}/secrets/mcp-bearer.cred` | 0600 bearer credential (HTTP mode; generated at install) |
| `MCP_LOG_REDACT` | `true` | redact `pocket_logs` output |
| `MCP_ALLOWED_LOGS` | core set | comma list of log basenames `pocket_logs` may read |
| `MCP_RATE_LIMIT` | `60/min` | per-session call cap |

(HTTP mode also reuses the admin panel's `CF_ACCESS_MODE` / `CF_ACCESS_TEAM_DOMAIN` /
`CF_ACCESS_AUD` for JWT validation — no new CF keys.)

## 12. Repository integration (the implementation this spec drives)

A single default-OFF commit, landed after the decisions in §13 are locked:

- **`scripts/mcp/pocket-mcp.py`** — the server: FastMCP tool/resource/prompt registrations +
  the security wrapper (tier gate, arg allowlist, audit, redaction) + the ASGI middleware for
  the HTTP transport.
- **`scripts/mcp/requirements.txt`** — the **version-pinned** (`==`) SDK dependency set
  (`mcp==…`, `uvicorn==…`, transitive `pydantic`/`anyio`/`starlette`), installed into a
  dedicated venv (no `--require-hashes` — see §6.1).
- **`scripts/steps/87-install-mcp.sh`** — self-gates on `ENABLE_MCP`. Creates the
  `~/pocket-mcp` venv, `pip install -r requirements.txt`, then a fail-loud
  `python -c "import mcp"` check. stdio mode: install a `pocket-mcp` launcher on `PATH` that
  `exec`s the venv python in stdio mode. HTTP mode: generate the bearer credential, drop
  `mcp.caddy` into `/etc/caddy/apps/`, `caddy validate`, and `supervise mcp -- …` the uvicorn
  ASGI server.
- **`.env.example` / `setup.sh`** — the keys in §11 (gated prompts; secrets via `read -rs`,
  off argv; avoid the `${POCKET_LOG_DIR}` expand-trap).
- **`scripts/install.sh`** — `mcp:steps/87-install-mcp.sh` in `core_steps` (self-gating, like
  every other optional step).
- **`admin/app.py`** — a health row for the `mcp` service (HTTP mode only; pattern
  cross-checked against the real supervised argv) + `ENABLE_MCP` in the enable map.
- **`config` / Caddy** — `mcp.caddy` template (fresh subdomain host → `/etc/caddy/apps/*`,
  no core-vhost weave needed).
- **`docs/MCP.md`** — the operator connect/runbook guide (this file, `MCP_SERVER_SPEC.md`,
  is the *design*; `MCP.md` will be the *how-to*).
- **README / CHANGELOG / ARCHITECTURE** — features + roadmap + `[Unreleased]` entry +
  component row.

## 13. Decisions (locked 2026-06-20)

The pivotal choices, settled by the operator:

1. **Transport — both, stdio default.** Ship stdio-over-SSH (the simple single-operator path)
   *and* the optional Streamable-HTTP transport on `mcp.${DOMAIN}` for the claude.ai connector,
   accepting the extra Caddy vhost + bearer plumbing.
2. **Mutation policy — read + operate.** Read tools always on; the operate tier behind
   `MCP_ALLOW_OPERATE` (default false). The **danger** tier (panic) is still implemented but
   stays off behind `MCP_ALLOW_DANGER` (default false) + a per-call typed confirm.
3. **Implementation — official `mcp` SDK** (FastMCP), in a pinned Termux venv (§6.1, §7). The
   trade-off accepted: a `pydantic-core` / `uvicorn` dependency and an operator-verified
   on-device build, in exchange for spec conformance and lower protocol-maintenance burden.
4. **Tool scope — full optional set in v1:** `pocket_matrix_users`, `pocket_honeypot_recent`,
   the read-only `pocket_restore_describe`, **and** the guided prompts (`triage`,
   `health-report`) all ship.

## 14. Future work

- Server-initiated streaming over SSE (progress for long backups), MCP `sampling`, and
  `elicitation` (interactive confirmations) — deliberately out of v1 (all current tools are
  request/response).
- **OAuth 2.1 for remote MCP** — the bundled `matrix-auth-gw` is already an OIDC IdP
  (`OIDC_ENABLED`, `/authgw/oidc/authorize` + `/token`). A future HTTP transport could
  delegate auth to it per the MCP authorization spec, replacing the CF-Access + bearer combo
  for operators who run the gateway. v1 stays on CF Access (simpler, already in the stack).
- A `resources/subscribe` channel for live status push.

## 15. References

- Existing patterns reused: `admin/app.py` (`_cfa_validate`, `log_audit`, `gather_stats`,
  `_proc_alive`, danger-zone confirm), `scripts/email/snappymail/webmail-admin.caddy.tmpl`
  (`@no_cf_jwt` fail-closed), `scripts/gateway/matrix-auth-gw.py` (stdlib HTTP + rate limit +
  OIDC IdP), `scripts/ops/*` (the wrapped operations), `scripts/lib/common.sh` (env + service
  registry).
- Model Context Protocol specification (revision 2025-06-18).
