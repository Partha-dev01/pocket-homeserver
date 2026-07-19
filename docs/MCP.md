# MCP server (optional)

An optional **Model Context Protocol** server that lets an MCP client — Claude
Desktop, Claude Code, the claude.ai web connector, or any other MCP host — observe
and operate the stack through a small, audited set of tools: "show me the stack
status", "tail the Caddy log", "restart the linkding service", "back up the Matrix
database now". It is **off by default** (`ENABLE_MCP`).

It is a **thin protocol adapter** — it introduces no new privileged operation.
Every read tool reuses the probes the admin panel already runs; every mutating
tool shells out to an already-vetted `scripts/ops/*` script with a fixed argv.
Its security posture is the same as the web admin panel danger-zone and the
operator admin bot. For the full design rationale, transports, and threat model,
see the design spec, [MCP_SERVER_SPEC.md](MCP_SERVER_SPEC.md); **this** file is
the *how-to*.

- Server: [`scripts/mcp/pocket-mcp.py`](../scripts/mcp/pocket-mcp.py) (official `mcp` SDK / FastMCP)
- Installer: [`scripts/steps/87-install-mcp.sh`](../scripts/steps/87-install-mcp.sh)
- Runs **Termux-native** (it orchestrates the host — `proot-distro` restarts,
  supervisor pidfiles under `${POCKET_STATE_DIR}`, `pgrep` of host processes), in a
  dedicated venv (`~/pocket-mcp`), like the admin panel. Secrets + state live on the
  large volume under `${DATA_DIR}/secrets`.

## What it does

The one server offers two transports — pick with `MCP_TRANSPORT`:

1. **stdio-over-SSH (the recommended default).** The MCP client spawns the server
   over your existing SSH session to the phone; **the SSH session is the
   authentication**. No port is published, no bearer credential is needed, nothing
   new is exposed. This is the simple single-operator path.
2. **Streamable HTTP (optional remote).** For clients that connect over the network
   (e.g. the claude.ai connector). Served on a dedicated Caddy vhost
   `mcp.${DOMAIN}` → loopback, **fail-closed behind Cloudflare Access** plus a
   bearer credential. Off unless you set `MCP_TRANSPORT=http` (or `both`).

Tools are organised into three **tiers** by risk — **read**, **operate**,
**danger** — and each tier above read is behind its own env flag (default off).
`tools/list` only advertises the tools whose tier is enabled, so a client never
sees a tool it cannot call. See [Tool reference](#tool-reference) below.

## Enabling it

```bash
# in .env (or pick these in ./setup.sh)
ENABLE_MCP=true
MCP_TRANSPORT=stdio        # stdio (default) | http | both
# operate / danger tiers stay OFF until you opt in (see Tool reference):
# MCP_ALLOW_OPERATE=true
# MCP_ALLOW_DANGER=true

# then install
./pocket.sh        # choose "Install"
# or directly:
bash scripts/install.sh
```

The install step ([`87-install-mcp.sh`](../scripts/steps/87-install-mcp.sh))
self-gates on `ENABLE_MCP`. It creates the `~/pocket-mcp` venv,
`pip install -r scripts/mcp/requirements.txt` (the **version-pinned** `mcp` SDK +
`uvicorn`), then runs a **fail-loud** `python -c "import mcp"` check — if the SDK
cannot be imported, the step stops with an error rather than installing a broken
server. In stdio mode it installs a tiny `pocket-mcp` launcher on your `PATH`. In
HTTP mode it additionally generates the bearer credential, drops `mcp.caddy` into
`/etc/caddy/apps/`, `caddy validate`s, and supervises the server. The step is
idempotent — safe to re-run.

> **Build caveat (Termux).** The `mcp` SDK pulls in `pydantic-core`, a compiled
> Rust extension. On Termux this needs either a prebuilt wheel for your CPU or a
> local Rust toolchain to build from source (`pkg install rust`), which can be slow
> on a phone. If the post-install `import mcp` check fails, that compile is almost
> always why — install `rust` (and `binutils`) and re-run the step. This is an
> operator-verified on-device build, the same kind of step as the BYO-llama and
> Maddy builds.

## Connecting over stdio (SSH) — recommended

No new auth, nothing published. The client runs `ssh <your-ssh-host> pocket-mcp`
and talks JSON-RPC over that channel. Replace `<your-ssh-host>` with the SSH host
alias you already use to reach the phone (the one in your `~/.ssh/config`).

**Claude Desktop** — add to its `claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "pocket": {
      "command": "ssh",
      "args": ["<your-ssh-host>", "pocket-mcp"]
    }
  }
}
```

**Claude Code** — either add a project `.mcp.json` with the same block, or:

```bash
claude mcp add pocket -- ssh <your-ssh-host> pocket-mcp
```

The `pocket-mcp` launcher sources your env and `exec`s the server in stdio mode.
Messages are newline-delimited JSON-RPC on stdin/stdout; **all diagnostics go to
stderr** (stdout is the protocol channel, so the launcher never prints to it). If
the client reports the server "exited" or "spoke garbage", run
`ssh <your-ssh-host> pocket-mcp` by hand and read the stderr it prints.

## Connecting over HTTP (optional remote)

Use this only if you need a client that connects over the network (e.g. the
claude.ai custom connector). It publishes a hostname, so it is fail-closed behind
**three independent gates** — get any one wrong and the server refuses you.

1. Set the transport and (re-)install:

   ```bash
   # in .env
   MCP_TRANSPORT=http        # or "both" to keep stdio too
   MCP_HTTP_HOST=mcp         # → mcp.${DOMAIN}
   # HTTP mode also validates the Cloudflare Access JWT in-process (always enforced
   # when a team domain is set); reuse the same CF Access keys the admin panel uses:
   CF_ACCESS_TEAM_DOMAIN=<your-team>.cloudflareaccess.com
   CF_ACCESS_AUD=<the Access application AUD tag>

   bash scripts/install.sh --force
   ```

2. **Publish `mcp.${DOMAIN}`** as a Cloudflare Tunnel hostname **and attach a
   Cloudflare Access (Zero Trust) policy to it** — exactly like the admin panel
   hostname. Without an Access policy the first gate rejects every request. (Not
   done by the script; see [APP_AUTH.md](APP_AUTH.md).)

3. **The bearer credential.** The install step generates a `0600` credential file
   at `MCP_BEARER_TOKEN_FILE` (default `${DATA_DIR}/secrets/mcp-bearer.cred`). Read
   it once to configure the client:

   ```bash
   cat "${DATA_DIR}/secrets/mcp-bearer.cred"   # the only time you read it
   ```

   The client must send it as `Authorization: Bearer <value>`. It is checked with a
   constant-time compare; it is never echoed by the server, never on argv, never
   returned by any tool.

4. **claude.ai connector.** Add a custom connector pointing at
   `https://mcp.${DOMAIN}/` and supply the bearer value above. You will also pass
   the Cloudflare Access service-token / login the same way you reach any other
   Access-protected app.

### The three HTTP gates (why a request can be refused)

| Gate | Where | Rejects |
|---|---|---|
| 1. Cloudflare Access **presence** | Caddy edge (`@no_cf_jwt` → `403`) | any request with no `Cf-Access-Jwt-Assertion` header — i.e. it never passed an Access policy (direct-to-origin probe, or a hostname with no policy attached) |
| 2. RS256 **JWT validation** | in-process (reuses the admin panel's CF-Access validator) | a forged/expired/wrong-audience Access token; the validated Access email becomes the audited caller identity |
| 3. **Bearer** credential | in-process (`compare_digest`) | a missing/wrong `Authorization: Bearer` — so a misconfigured Access policy alone cannot open the server |

stdio mode has none of this plumbing — its single gate is the SSH/CF-Access channel
itself.

## Tool reference

Tiers, mirroring the spec. A tool that is gated off is **not registered**, so it
never appears in `tools/list` and a call to it is refused.

### READ tier — always on when `ENABLE_MCP=true`

| Tool | Returns |
|---|---|
| `pocket_status` | overall stack snapshot (services, uptime, disk, memory) |
| `pocket_health` | per-service up/down/**degraded** (pidfiles + crash-loop markers) + the 3 core HTTP probes (conduwuit, matrix-via-Caddy, admin `/login`) |
| `pocket_list_services` | supervised services and their liveness |
| `pocket_logs` | last N lines of an **allowlisted** log file, **redacted** |
| `pocket_config` | which subsystems are enabled (`ENABLE_*` + non-secret keys; **no secrets**) |
| `pocket_backups_list` | backups present (name / size / mtime; no contents) |
| `pocket_honeypot_recent` | recent honeypot events (only if `ENABLE_HONEYPOT`; the IPs are already-public attacker data) |
| `pocket_matrix_users` | Matrix user list / count, read-only (no tokens) |
| `pocket_restore_describe` | the restore **plan** (dry-run) — **never executes** anything |
| `pocket_doctor` | the full read-only preflight/self-test report (`ops/doctor.sh`), redacted |
| `pocket_metrics` | recent device/stack metrics + min/avg/max/current summary (only if `ENABLE_METRICS`; last N samples, capped at 500) |
| `pocket_problems` | only what's currently **wrong** — degraded / down services + failing probes; `ok: true` when all green |
| `pocket_audit_recent` | recent entries from the shared panel+MCP audit trail (last N, capped at 500, redacted) |
| `pocket_sites_list` | every deployed Pocket Pages site: active release, count, size, URL (only if `ENABLE_SITES`) |
| `pocket_site_releases` | one site's full release history + metadata (only if `ENABLE_SITES`) |
| `pocket_site_status` | a deploy/rollback/delete **job's** state + a redacted tail of its log (only if `ENABLE_SITES`; see the deploy how-to below) |

Read tools also surface as MCP **resources** (`pocket://status`,
`pocket://config`, `pocket://sites`, `pocket://metrics`, and
`pocket://docs/{name}` for this repo's runbooks, e.g. `pocket://docs/BACKUPS`)
and three guided **prompts**: `triage(service)` (walk the model through
diagnosing one service), `health-report` (summarise overall health), and
`deploy_report(site)` (summarise one site's deploy state — report-only by
design).

### OPERATE tier — set `MCP_ALLOW_OPERATE=true`

| Tool | What it does |
|---|---|
| `pocket_restart_service` | `ops/restart.sh <svc>` — `<svc>` validated against the supervised set |
| `pocket_restart_stack` | `start-stack.sh --restart` — matrix + Caddy + cloudflared in order, apps untouched (brief ingress blip, fully reversible) |
| `pocket_backup_db` | `ops/backup-db.sh` — stop-matrix → tar → restart; returns artifact metadata |
| `pocket_backup_all` | `ops/backup-all.sh` — full rootfs tar; returns artifact metadata (synchronous, bounded) |
| `pocket_rotate_backups` | `ops/rotate-backups.sh` — prune snapshots to the configured retention; no-op when nothing is due |
| `pocket_offsite_push` | `ops/offsite-push.sh` — push already-encrypted backups to the offsite bucket (only if `ENABLE_OFFSITE_BACKUP`; synchronous, bounded) |
| `pocket_rotate_registration_token` | `ops/rotate-registration-token.sh` — returns **metadata only**, never the token |
| `pocket_site_deploy` | `sites/site-deploy.sh` — deploy a **pre-staged** artifact as a new release; returns a job id immediately (only if `ENABLE_SITES`; see the how-to below) |
| `pocket_site_rollback` | `sites/site-rollback.sh` — instant pointer-swap back to a previous release (only if `ENABLE_SITES`) |

**User management** (each additionally needs `ENABLE_USER_ADMIN=true`, except
invite-mint, which is tier-gated only):

| Tool | What it does |
|---|---|
| `pocket_user_create` | `ops/user-create.sh <localpart>` — the **generated password is the reply** (the one tool family, with reset-password, whose return value is deliberately a fresh credential) |
| `pocket_user_reset_password` | `ops/user-reset-password.sh <localpart>` — same credential-return caveat |
| `pocket_user_suspend` | `ops/user-suspend.sh` — reversible; takes a localpart or a full `@user:server` MXID |
| `pocket_user_unsuspend` | `ops/user-unsuspend.sh` — lifts a suspension |
| `pocket_mint_invite_token` | `bootstrap/mint-invite-token.sh` — mint one-time invite tokens (this **is** the "invite" operation; `ops/user-invite.sh` forwards to the same script, so there is no separate `pocket_user_invite`) |

Enable the tier, then re-install so the change takes effect:

```bash
# in .env
MCP_ALLOW_OPERATE=true
bash scripts/install.sh --force
```

### DANGER tier — set `MCP_ALLOW_DANGER=true` **and** pass a per-call typed confirm

Implemented but off by default. Even with the flag on, each danger tool's schema
requires a `confirm` argument or the call is refused **before anything runs** —
exactly like the admin panel danger-zone. For the panic tools `confirm` must
equal the **tool name**; for the tools that take a target it must equal the
**target itself** (the site or user you are acting on) — a fixed phrase would
authorize acting on *any* target with one unchanging string.

| Tool | What it does | `confirm` must equal |
|---|---|---|
| `pocket_panic_soft` | `ops/panic-soft.sh` — drop the tunnel (the server goes dark, recoverable) | `pocket_panic_soft` |
| `pocket_panic_hard` | `ops/panic-hard.sh` — stop everything except the admin panel | `pocket_panic_hard` |
| `pocket_user_deactivate` | `ops/user-deactivate.sh` — close an account, effectively irreversible (also needs `ENABLE_USER_ADMIN`) | the `user` value, exactly as you typed it |
| `pocket_site_delete` | `sites/site-delete.sh` — delete a site **and all its release history** (also needs `ENABLE_SITES`) | the site name |

```bash
# in .env
MCP_ALLOW_DANGER=true
bash scripts/install.sh --force
```

### Not exposed

Interactive, two-phase, or paste-driven operations are **not** mutating tools:
`rotate-admin-password`, `rotate-tunnel-token`, `rotate-authgw-rs`,
`rotate-adminbot-token`, `rotate-all`, the backup daemon, and `restore` (offered
only read-only, as `pocket_restore_describe`). One-time bootstrap creation steps
are left to the TUI/CLI. Run those from `./pocket.sh`, the admin panel, or the CLI.
There is also deliberately no `pocket_user_invite` (invite-mint already covers it,
above) and no tool that accepts site content as an argument — artifacts are staged
out-of-band (next section).

## Deploying a site over MCP

MCP never carries the artifact bytes — a file-content tool argument would hold
the whole archive in memory as base64 inside one JSON-RPC message, with no way
to enforce the upload cap before parsing it (design decision AD-1 in
[specs/SPEC-MCP-COMPLETION.md](specs/SPEC-MCP-COMPLETION.md)). A deploy is
therefore two steps:

**1. Stage the artifact out-of-band.** Place a zip (or a plain directory) under
the sites module's staging directory — over the same SSH channel the stdio
transport already uses:

```bash
# the staging dir, as seen from Termux/SSH (it is /var/www/sites/.staging
# inside the userland — the same directory the panel's uploads stream into):
scp site.zip '<your-ssh-host>:$PREFIX/var/lib/proot-distro/installed-rootfs/debian/var/www/sites/.staging/'
```

Staged files are temporary: consumed or not, they are garbage-collected by age
(`SITES_JOB_RETENTION_DAYS`) by `site-gc.sh`.

**2. Deploy, then poll the job.**

- `pocket_site_deploy(site, staged_path)` validates the name and that
  `staged_path` resolves **inside** the staging directory, then launches the
  same `site-deploy.sh` pipeline the panel and CLI use, **detached** — it
  returns a job id immediately instead of blocking (a `node`-tier build alone
  can run for many minutes). Pass `build="hugo"` or `build="node"` to use the
  on-phone build tiers (see [SITES.md](SITES.md#build-tiers)).
- Poll `pocket_site_status(job_id)` every 3–5 seconds until `state` is `done`
  or `failed` (the record carries the error and a redacted tail of the deploy
  log). That cadence stays well inside the default `MCP_RATE_LIMIT` (60/min).
- If the new release is wrong: `pocket_site_rollback(site)` is an instant
  pointer swap — no rebuild, no redeploy.

Sites tools need `ENABLE_SITES=true`; deploy/rollback additionally need
`MCP_ALLOW_OPERATE=true`, and delete needs `MCP_ALLOW_DANGER=true` plus
`confirm` equal to the site name.

## Operations

```bash
# restart (HTTP mode only — stdio is launched on demand by the client):
bash scripts/ops/restart.sh mcp

# re-run the installer (idempotent; picks up .env changes — venv, launcher, vhost):
bash scripts/install.sh --force

# logs
tail "${POCKET_LOG_DIR}/mcp.log"

# smoke-test the stdio path by hand (reads stderr diagnostics):
ssh <your-ssh-host> pocket-mcp
```

In HTTP mode the server is supervised like any other service and appears in the
admin panel's health list. In stdio mode there is nothing to supervise — the
client spawns it per session.

## Security model

| Concern | Mitigation |
|---|---|
| Arbitrary command execution | each mutating tool is a fixed argv `subprocess.run([...])`; **no `shell=True`**; no tool accepts a path or a command |
| Argument injection | `service` validated against the live supervised set; `log` against the `MCP_ALLOWED_LOGS` allowlist; integers bounded |
| Secret exfiltration | rotation tools return metadata only; `pocket_logs` output is redacted (token/key/bearer patterns); `pocket_config` filters to `ENABLE_*` + known non-secret keys |
| Unauthorised mutation | operate + danger tiers each behind their own env flag, default off; danger also needs a typed confirm |
| Remote exposure (HTTP) | three independent gates — Caddy `@no_cf_jwt` `403`, in-process RS256 JWT validation, `0600` bearer (`compare_digest`) |
| stdio exposure | authentication is the SSH / CF-Access channel itself; nothing is published |
| Abuse / runaway | per-session rate limit (`MCP_RATE_LIMIT`, default `60/min`) |
| Forensics | **every `tools/call` is audited** to the same log the admin panel uses — caller (CF-Access email over HTTP, or `ssh` over stdio), tool name, redacted args, result status |
| Fail-closed | unknown tool → error; a gated-off tier's tools are not listed and any call is refused; any exception → an error result, never a partial side effect |

**Credential hygiene.** The HTTP bearer lives in a `0600` file under
`${DATA_DIR}/secrets/`, generated at install — never echoed, never on argv, never
returned by any tool, the same discipline as `CF_TUNNEL_TOKEN` and the adminbot
credential.

## Configuration reference

| `.env` variable | Default | Meaning |
|---|---|---|
| `ENABLE_MCP` | `false` | Master switch for this step. |
| `MCP_TRANSPORT` | `stdio` | `stdio` \| `http` \| `both`. |
| `MCP_HTTP_HOST` | `mcp` | Subdomain label → `mcp.${DOMAIN}` (HTTP mode). |
| `MCP_HTTP_PORT` | `9120` | Loopback bind port (HTTP mode; Caddy fronts it). |
| `MCP_ALLOW_OPERATE` | `false` | Enable the operate tier. |
| `MCP_ALLOW_DANGER` | `false` | Enable the danger tier (still needs a per-call typed confirm). |
| `MCP_BEARER_TOKEN_FILE` | `${DATA_DIR}/secrets/mcp-bearer.cred` | `0600` bearer credential (HTTP mode; generated at install). |
| `MCP_LOG_REDACT` | `true` | Redact `pocket_logs` output. |
| `MCP_ALLOWED_LOGS` | core set | Comma-separated log basenames `pocket_logs` may read. |
| `MCP_RATE_LIMIT` | `60/min` | Per-session call cap. |

HTTP mode also reuses the admin panel's `CF_ACCESS_TEAM_DOMAIN` / `CF_ACCESS_AUD`
for in-process JWT validation — no new Cloudflare keys. Unlike the admin panel, the
HTTP transport always enforces the JWT when a team domain is set (it does not honor
a `CF_ACCESS_MODE=log` permissive mode — a remote surface is fail-closed).

Four existing app flags additionally gate their own tool groups (no new keys —
the MCP server reads the same `.env` values every other surface does):
`ENABLE_SITES` (the sites tools), `ENABLE_USER_ADMIN` (the user-management
tools), `ENABLE_METRICS` (`pocket_metrics` + `pocket://metrics`), and
`ENABLE_OFFSITE_BACKUP` (`pocket_offsite_push`).

## Troubleshooting

- **`import mcp` fails at install (the post-install check stops the step).** The
  `pydantic-core` Rust extension could not be installed/built on Termux. Install a
  toolchain (`pkg install rust binutils`) and re-run
  `bash scripts/install.sh --force`. See the *Build caveat* above.
- **A tool is missing from `tools/list`.** Its tier flag is off — operate tools
  need `MCP_ALLOW_OPERATE=true`, danger tools `MCP_ALLOW_DANGER=true` — **or**
  its module flag is off: `pocket_honeypot_recent` needs `ENABLE_HONEYPOT=true`,
  the sites tools `ENABLE_SITES=true`, the user-management tools
  `ENABLE_USER_ADMIN=true`, `pocket_metrics` `ENABLE_METRICS=true`, and
  `pocket_offsite_push` `ENABLE_OFFSITE_BACKUP=true`. Set the flag and re-install
  with `--force` (stdio mode picks it up on the next client launch).
- **A danger tool is listed but every call is refused.** The `confirm` argument
  is missing or wrong — it must equal the tool name (panic tools) or the exact
  target (`pocket_site_delete`: the site name; `pocket_user_deactivate`: the
  `user` value as you typed it).
- **`pocket_site_deploy` refuses the `staged_path`.** The path must resolve
  *inside* the staging directory (see the deploy how-to above) — stage the
  artifact there first; symlinks or `..` that escape it are rejected, and MCP
  never accepts file content directly.
- **HTTP `403` Forbidden.** Cloudflare Access is not in front of `mcp.${DOMAIN}` —
  the `@no_cf_jwt` gate rejected the request because it carried no Access
  assertion. Publish the hostname through the tunnel **and** attach an Access policy
  (gate 1). A `401`/bearer rejection instead means gate 3 — recheck the
  `Authorization: Bearer` value against `MCP_BEARER_TOKEN_FILE`.
- **stdio client says the server "exited" or returned junk.** Run
  `ssh <your-ssh-host> pocket-mcp` by hand and read the stderr — diagnostics go
  there, never to stdout (which is the JSON-RPC channel).

## Disabling the MCP server

Set `ENABLE_MCP=false` in `.env`. In HTTP mode also stop the service:

```bash
bash scripts/ops/restart.sh mcp   # picks up nothing to start
```

In stdio mode just remove the `pocket` entry from your client config. The venv and
the bearer credential under `${DATA_DIR}/secrets` are left in place so you can
re-enable later without reconfiguring.

## See also

- [MCP_SERVER_SPEC.md](MCP_SERVER_SPEC.md) — the design spec (transports, tiers, threat model).
- [specs/SPEC-MCP-COMPLETION.md](specs/SPEC-MCP-COMPLETION.md) — the v1.1.0 sites + parity tool design (M3).
- [SITES.md](SITES.md) — Pocket Pages itself: the pipeline the sites tools drive.
- [ADMIN.md](ADMIN.md) — the web admin panel: the same ops surface, in a browser.
- [ADMINBOT.md](ADMINBOT.md) — the Matrix admin bot: the same ops surface, in chat.
- [APP_AUTH.md](APP_AUTH.md) — the Cloudflare Access model used by the HTTP transport.
- [SECURITY.md](SECURITY.md) — threat model and trust boundaries.
