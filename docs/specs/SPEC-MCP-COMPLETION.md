# SPEC-MCP-COMPLETION — Pocket Pages: complete the MCP server (`sites` tool group + operator parity)

**Status: APPROVED 2026-07-19 (operator) — OQ resolutions recorded at the end of §13; §14 lists the
plan/shipped-code conflicts this design already accounts for.**

Milestone: M3 of the Pocket Pages program (v1.1.0). Depends on:
[SPEC-SITES-PIPELINE.md](SPEC-SITES-PIPELINE.md) (M1, APPROVED — job model AD-6, registry schema §5, name
validation §7, filesystem layout §4) and [SPEC-SITES-PANEL.md](SPEC-SITES-PANEL.md) (M2, APPROVED — the
panel's own `sites` tool wrappers are the closest prior art for every design decision below; where this
spec reuses a panel pattern verbatim it says so and cites the line). Related (parallel/later):
SPEC-LANDING-SYNC.md (M2, ships alongside the panel), SPEC-DIFFERENTIATORS (M4).

This spec's task, verbatim from the program plan: **"complete the MCP server to the fullest"** — add the
`sites` tool group so the same Pocket Pages capability the panel (M2) exposes in a browser is reachable
from an MCP client, and close the parity gap between the MCP server's read/operate surface and what the
web admin panel and the ops script tree already offer (health depth, doctor, metrics, problems, audit,
backup rotation/offsite push, user management).

---

## 0. Prerequisite check — M1 and M2 are code-complete

M1 landed in full (public main commit `c1273c7`, hardened in `c478403`): the pipeline scripts
(`scripts/sites/site-deploy.sh`, `site-rollback.sh`, `site-list.sh`, `site-delete.sh`, `site-gc.sh`,
`lib-sites.sh`, `reserved-subs.sh`, `safe_extract.py`), the job model (`${POCKET_STATE_DIR}/site-job-<id>.json`
+ `${POCKET_LOG_DIR}/site-deploy-<id>.log`), and the registry (`${SITES_ROOT}/.registry.json`). M2's admin-panel
Sites surface is code-complete in the working tree (not yet a public commit at spec-drafting time): `admin/app.py`
carries `SITE_SUB_RE`/`SITE_RESERVED` (`admin/app.py:2739-2744`), `run_script_argv`/`run_script_detached_argv`
(`admin/app.py:2776-2810`), `_read_sites_registry`/`_route_collision` (`admin/app.py:2813-2833`), and the full
`/sites/*` route family (`admin/app.py:3055-3420`, including the job-status poll at `admin/app.py:3234-3249`
and the danger-tier delete flow at `admin/app.py:3278-3353`). This spec designs the MCP tool group **against
that shipped panel contract**, not against the M2 draft's original sketches — per the standing rule from
SPEC-SITES-PANEL §0, *where a code sketch below disagrees with a shipped script or the shipped panel, the
shipped code wins*, and every such case found during research is called out explicitly (§14 lists them).

The MCP server itself is also already shipped and marked `IMPLEMENTED` — `docs/MCP_SERVER_SPEC.md` records
it as "shipped in v0.3.0", and `scripts/mcp/pocket-mcp.py` (1099 lines) is a working FastMCP server with three
registration-gated tiers (READ always-on, OPERATE behind `MCP_ALLOW_OPERATE`, DANGER behind `MCP_ALLOW_DANGER`
+ a per-call typed confirm), a closed-world backing-script runner (`_run_ops`, `pocket-mcp.py:328-349`), secret
redaction (`_redact`, `pocket-mcp.py:260-279`), a shared audit trail (`_audit`, `pocket-mcp.py:283-308`), and a
fail-closed HTTP transport. This spec **extends** that file — it does not replace it, and every new tool follows
the exact conventions the existing 14 tools already establish.

## 1. Goal

Two things, both scoped to `scripts/mcp/pocket-mcp.py` (plus the doc updates it implies, §10):

1. **A new `sites` tool group** so an MCP client can list sites, inspect release history, deploy a
   pre-staged artifact, poll a deploy job, roll back, and (danger-gated) delete — the same six operations
   the M2 panel exposes, reached the way every other MCP tool here is reached: a thin wrapper around the
   already-vetted M1 pipeline scripts, never a new privileged code path.
2. **Parity tools** that close the gap between what the panel/CLI can already tell the operator (health
   depth, doctor, metrics, problems, audit trail, backup rotation, offsite push, user lifecycle) and what
   the MCP server currently exposes, so an operator working entirely from an MCP-capable chat client is not
   missing capabilities they'd otherwise have to SSH in for.

## 2. Non-goals (M3)

- **OAuth 2.1 for remote MCP.** `docs/MCP_SERVER_SPEC.md` §14 already named this future work; it stays future
  work. The static scoped bearer + Cloudflare Access JWT combo (`pocket-mcp.py:975-1027`) remains the
  sanctioned single-operator HTTP-transport auth for v1.1.0. (A future gateway-delegated OAuth flow is still
  possible later, unchanged from the original spec's framing.)
- **Restore execution.** `pocket_restore_describe` (`pocket-mcp.py:728-741`) stays read-only/dry-run-only,
  exactly as `docs/MCP_SERVER_SPEC.md` §8.4 originally decided. No new restore-executing tool is added here.
- **Interactive/two-phase rotations.** `rotate-admin-password`, `rotate-tunnel-token`, `rotate-authgw-rs`,
  `rotate-adminbot-token`, `rotate-all` stay excluded (§8.4's list, unchanged) — they need an interactive
  paste or a manual env edit that has no sane MCP shape.
- **SSE / server-push transport changes.** All tools remain request/response, exactly as `docs/MCP_SERVER_SPEC.md`
  §6.2 already decided ("no SSE needed in v1"). The sites tool group's job-status polling (§6 below) is a
  client-side poll loop against a plain read tool, never a new streaming transport.
- **Uploading site content over MCP.** `pocket_site_deploy` takes an already-staged path; it never accepts
  raw bytes as a tool argument. See AD-1 — this is the single most consequential scope boundary in this spec.
- **A `pocket_sites_rebuild_registry` tool.** The panel's `/sites/rebuild-registry` button
  (`admin/app.py`, `SCRIPTS_OK["sites-rebuild-registry"]`) is a self-healing escape hatch for a
  panel-operator hitting a stale/corrupt registry visually; it is not part of the M3 program-plan tool list,
  and adding it would need its own confirm-shape discussion. Left for a follow-up if the operator asks.
- **A second async/detached-launch pattern beyond site deploy.** `pocket_offsite_push` and
  `pocket_backup_all` (already shipped) stay synchronous, bounded by `OPS_TIMEOUT_DEFAULT` — see AD-2 and
  §14 finding 3.

## 3. Architecture decisions

### AD-1 — `pocket_site_deploy` takes a pre-staged path; MCP never carries the artifact bytes

The program-plan sketch is `pocket_site_deploy(site, staged_path)` — no upload tool is named anywhere in
the M3 scope, and that omission is deliberate, not an oversight this spec should "complete". SPEC-SITES-PANEL
AD-3 (`docs/specs/SPEC-SITES-PANEL.md:76-96`) already worked through why a large binary artifact cannot
safely ride inside a request that also carries structured metadata: Werkzeug's multipart parser buffers to
its own temp file before a byte cap or destination path can be enforced. The equivalent problem is *worse*
for an MCP tool call — the JSON-RPC wire format has no raw-byte-stream concept at all; a "content" argument
would have to be base64 (≈33% inflation) held **entirely in memory** as a single `tools/call` parameter,
with no chunking, no progress, and no way to enforce `SITES_MAX_UPLOAD_MB` before the whole blob is already
parsed. For a 200 MB cap that is a >260 MB in-memory JSON parse per call — unacceptable on a phone.

**Decision:** `pocket_site_deploy(site, staged_path, build="none")` accepts a path the operator (or another
channel — `scp`/`rsync` into `${SITES_ROOT}/.staging/`, or a future webhook in M4) has **already placed**
under the sites module's staging directory. The tool's job is to validate `staged_path` is realpath-contained
inside that directory (§5) and then hand it to `site-deploy.sh` exactly as the panel does after its own
streamed-to-disk upload (`admin/app.py:3106-3170`, specifically the `run_script_detached_argv` call at the
end of `sites_upload()`). This is stated as an explicit non-goal in §2 so a future reader doesn't mistake the
omission for incompleteness.

### AD-2 — one new detached/async execution primitive, scoped to exactly one tool

Every mutating tool `pocket-mcp.py` ships today is **synchronous**: `_run_ops` (`pocket-mcp.py:328-349`) is a
blocking `subprocess.run(..., timeout=timeout)` — even `pocket_backup_all` (`pocket-mcp.py:777-785`), which
can run for minutes, blocks the `tools/call` for its full `OPS_TIMEOUT_DEFAULT` (600s, `pocket-mcp.py:225`).
A site deploy can legitimately run past that: `SITES_BUILD_TIMEOUT` defaults to 900s for the `node` tier
alone (`scripts/sites/lib-sites.sh` via `site-deploy.sh:264-266`), and the M3 program plan explicitly calls
for a **job-id + status-poll pattern** (scope item 3) — meaning `pocket_site_deploy` must return almost
immediately with a job id, not block until the deploy finishes.

This requires a genuinely new primitive: a detached-launch helper. The closest prior art is the panel's
`run_script_detached_argv` (`admin/app.py:2793-2810`), which this spec ports almost verbatim:

```python
# New — mirrors admin/app.py:2793-2810 (run_script_detached_argv) almost verbatim,
# adapted to _run_ops's realpath-containment + allowlist discipline instead of
# SCRIPTS_OK. Scoped to exactly ONE caller (pocket_site_deploy, §5) — every other
# mutating tool in this file stays synchronous via _run_ops (see AD-2's rationale
# for NOT extending this to pocket_offsite_push/pocket_backup_all).
_DETACHED_ALLOWLIST = frozenset(("sites/site-deploy.sh",))
_MCP_ASYNC_LOG = "mcp-async.log"  # shared sink for every detached MCP-launched script


def _run_ops_detached(script_name, *args):
    """Launch an ALLOWLISTED backing script DETACHED (subprocess.Popen, not run) —
    for the one mutating tool whose backing script can outlive a reasonable
    tools/call timeout. Output goes to LOGS/mcp-async.log (mirrors adminweb's
    single shared async sink, admin/app.py:590) — per-JOB progress is read back
    separately from the job's OWN log file (site-deploy-<job>.log), never from
    this shared sink. Returns True/False (launch succeeded), never raises."""
    if script_name not in _DETACHED_ALLOWLIST:
        raise ValueError(f"refusing to detach-launch non-allowlisted script {script_name!r}")
    scripts_root = os.path.realpath(SCRIPTS)
    path = os.path.realpath(os.path.join(SCRIPTS, script_name))
    if path != scripts_root and not path.startswith(scripts_root + os.sep):
        raise ValueError("resolved script path escapes the scripts/ tree")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"backing script not found: {script_name}")
    cmd = ["bash", path, *[str(a) for a in args]]
    sink = os.path.join(LOGS, _MCP_ASYNC_LOG)
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(sink, "ab", buffering=0) as lf:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=lf, stderr=lf,
                              start_new_session=True, close_fds=True)
        return True
    except Exception:
        return False
```

**Why this is NOT extended to `pocket_offsite_push` or `pocket_backup_all`** (both named in the M3 scope
under the OPERATE tier, not the job-id-pattern list): the program plan's own scope item 3 names only
`backup_all` and `site_deploy` as candidates for the pattern, but `backup-all.sh`/`offsite-push.sh` have
**no job-state-file contract at all** — `job_start`/`job_done`/`job_fail` (`lib-sites.sh:342-427`) are a
`sites`-module-only convention from SPEC-SITES-PIPELINE AD-6; `ops/backup-all.sh` and `ops/offsite-push.sh`
just print progress to stdout and exit. Building a parallel job-file convention for those two scripts is a
`scripts/ops/*.sh` change — out of scope for an MCP-only spec (this milestone touches
`scripts/mcp/pocket-mcp.py` and its docs, nothing under `scripts/ops/`). **Decision: keep
`pocket_backup_all` and the new `pocket_offsite_push` synchronous**, bounded by the existing
`OPS_TIMEOUT_DEFAULT` (600s), unchanged in contract from what's already shipped for `pocket_backup_all`. This
is flagged as a plan/shipped-code tension in §14 finding 3, with a recommendation for a *future* milestone
that gives `ops/backup-all.sh` its own job-file convention before extending the MCP job-poll pattern to it.

### AD-3 — sites reads go straight to the registry file, never through a subprocess

`pocket_sites_list` and `pocket_site_releases` are pure reads. SPEC-SITES-PANEL AD-2
(`docs/specs/SPEC-SITES-PANEL.md:67-75`) already made this exact call for the panel's `GET /sites`: read
`.registry.json` directly with `json.load()` rather than shelling out to `site-list.sh --json`, because the
registry is explicitly *derived state* (SPEC-SITES-PIPELINE §5) that self-heals via `--rebuild`, and a
subprocess-per-read adds needless latency for a value that's just a `cat` of a small JSON file
(`scripts/sites/site-list.sh:47-49` — `--json` mode is *itself* nothing more than `cat "${REGISTRY}"`). The
shipped panel constants this spec ports are `admin/app.py:79-83` (`PD_BASE`/`SITES_ROOT`/`SITES_STAGING`/
`SITES_REGISTRY`) and `admin/app.py:2739-2744` (`SITE_SUB_RE`/`SITE_RESERVED`) — see §5 for the pocket-mcp.py
copies.

**Consequence — a third copy of the same duplication contract.** `lib-sites.sh` already tracks
`RESERVED_SUBS` (`scripts/sites/reserved-subs.sh:39`), and `admin/app.py` tracks a second copy
(`SITE_RESERVED`, `admin/app.py:2740-2744`) with its own parity test (`tests/test_panel_sites.py:136-144`,
`test_reserved_list_parity_with_pipeline`). This spec's `pocket-mcp.py` copy is a **third** hand-maintained
mirror of the identical list. §12 requires the new test suite assert parity against *both* existing copies
(not just the shell source), and §14 flags the three-way duplication as a real, growing maintenance smell
worth factoring into one shared file in a later milestone — not fixed here (fixing it means editing
`lib-sites.sh`, `admin/app.py`, *and* `pocket-mcp.py` in one diff, which is bigger than "complete the MCP
server").

### AD-4 — DANGER-tier confirm strings for parameterized tools are bound to the target, not a fixed phrase

The two shipped DANGER tools (`pocket_panic_soft`, `pocket_panic_hard`, `pocket-mcp.py:837-857`) take **no
target argument** — `confirm` is checked against the tool's own name via `_require_confirm(confirm, phrase)`
(`pocket-mcp.py:828-832`), which is safe precisely *because* there is nothing to confuse: every call to
`pocket_panic_hard` has identical blast radius. The two new parameterized DANGER tools
(`pocket_site_delete(site, confirm)`, `pocket_user_deactivate(user, confirm)`) do **not** share that
property — a fixed phrase like `"pocket_site_delete"` would authorize deleting *any* site with the same
unchanging string, which is exactly the kind of confused-deputy gap an LLM-driven caller can hit: a `confirm`
value copied from an earlier turn, or a stale value re-sent across a multi-step conversation, would silently
authorize a *different* target than the one the operator actually reviewed.

**Decision:** for a parameterized DANGER tool, `confirm` must exactly equal the target identifier itself,
reusing the existing generic `_require_confirm(confirm, phrase)` helper unmodified — it already takes
`phrase` as a per-call argument, so no code change to that function is needed, only a different value passed
at each call site. This is not an invented convention — it mirrors two pieces of already-shipped behavior:

1. `site-delete.sh`'s own **interactive** confirmation (`scripts/sites/site-delete.sh:55-59`) literally
   prompts "Type the site name to confirm" and compares it against the site name — a check that is bypassed
   for *any* non-interactive caller passing `--yes` (including the panel and, now, MCP). Requiring
   `confirm == site` at the MCP layer restores the equivalent protection for a caller that can never satisfy
   the script's own tty-gated prompt.
2. The admin panel's shipped user-deactivate flow (`admin/app.py:3703` — `_USER_OPS["deactivate"]` sets
   `needs_confirm=True`; `admin/app.py:3816-3820` compares the typed `confirm` field against `val`, the
   *exact string the operator typed as the target*, not a fixed phrase). `pocket_user_deactivate`'s design
   below is a direct, faithful port of this already-shipped panel behavior — not a new design choice for that
   tool, only for `pocket_site_delete` (which has no existing MCP or non-interactive-CLI precedent to copy).

### AD-5 — closed-world validation at the MCP layer is defense-in-depth, not the only gate

Every backing script this spec's new tools call already validates its own user-derived input before doing
anything: `validate_site_name()` (`scripts/sites/lib-sites.sh:94-116`) rejects a malformed or reserved site
name inside `site-deploy.sh`/`site-rollback.sh`/`site-delete.sh` regardless of what called them;
`validate_release_id()` (`lib-sites.sh:123-132`) checks both regex shape *and* on-disk existence before a
rollback target is trusted; the `ops/user-*.sh` scripts each grep-validate their own localpart/MXID argument
(e.g. `scripts/ops/user-suspend.sh:20-27`) before calling `matrix_admin.py`. **The MCP tool wrappers below
still duplicate these checks** (regex + closed-world membership, before ever building an argv or spawning a
subprocess) for the same reason the admin panel does (`admin/app.py:3117`, `:3259`, `:3283` all re-check
`SITE_SUB_RE` even though the scripts they call would refuse anyway): a friendly `ValueError` beats a
subprocess spawn followed by parsing a bash `die` message out of combined stdout+stderr, and it means a
malformed name is never even transiently placed on an argv list. This spec is explicit that **the script is
still the authoritative last-mile gate** — the MCP-side checks narrow the failure mode and improve the error
message, they are not the sole reason injection is impossible.

One concrete consequence of this layering, worth stating plainly: because `_run_ops` and the new
`_run_ops_detached` never attach a controlling terminal to the child process, `site-deploy.sh`'s own
non-interactive staging-containment check (`scripts/sites/site-deploy.sh:87-94`, gated on `[ ! -t 0 ]`) is
**always** the live branch for every MCP-originated deploy — the script enforces the staging-path
containment itself, independently of whatever the MCP wrapper already checked. §14 finding 5 flags that
`_run_ops`'s existing `subprocess.run` call (`pocket-mcp.py:344`) does not *explicitly* pass
`stdin=subprocess.DEVNULL` the way the panel's equivalent helpers do (`admin/app.py:2806`,
`tests/test_pipeline.py:89`) — it currently relies on inheriting a non-tty stdin from the MCP server process
itself, which is true in both transports today but is not a self-documenting guarantee the way an explicit
kwarg is. This spec calls for that explicit kwarg to be added to `_run_ops` as part of implementing M3 (a
one-line hardening fix to already-shipped code, not new functionality).

### AD-6 — `pocket_mint_invite_token` already covers the "invite" user-mgmt op; no second tool is added

The M3 scope lists "user mgmt (create/reset_password/suspend/unsuspend/invite)" under the OPERATE tier. Four
of those five map cleanly to new tools (§7). The fifth — invite — does **not** need a new tool:
`ops/user-invite.sh` is a two-line wrapper (`scripts/ops/user-invite.sh:23`,
`exec bash .../bootstrap/mint-invite-token.sh "${n}"`) around the **exact same script**
`pocket_mint_invite_token` already wraps directly (`pocket-mcp.py:787-802`,
`_run_ops("bootstrap/mint-invite-token.sh", n, ...)`). Adding `pocket_user_invite(count)` as a second tool
calling the same underlying script through a different path would be a redundant near-duplicate with a
confusingly different name and a different validated range (shipped: 1–50, `pocket-mcp.py:797-798`; the
wrapper script itself: no upper bound, `scripts/ops/user-invite.sh:18-21`, and `mint-invite-token.sh` itself
has no bound either, `scripts/bootstrap/mint-invite-token.sh:30`). **Decision: do not add a
`pocket_user_invite` tool.** `pocket_mint_invite_token` is the invite-mint capability; the user-mgmt group
in §7 covers create / reset-password / suspend / unsuspend (four tools, not five) plus the DANGER-tier
deactivate. This is called out as a plan/shipped-code conflict in §14 finding 1.

### AD-7 — `pocket_health` gets HTTP probes + degraded-marker awareness, closing a real doc/implementation gap

This is not purely new scope — it is closing a gap that already exists between what `docs/MCP_SERVER_SPEC.md`
documents and what shipped. The v0.3.0 design doc's own capability table says `pocket_health` wraps "admin
`HEALTH_PROCS` / HTTP checks" and returns "per-service up/down + the probe used"
(`docs/MCP_SERVER_SPEC.md:214`; `docs/MCP.md:170` repeats the same claim). The **shipped** `pocket_health()`
(`pocket-mcp.py:544-560`) does neither: it only reads `${POCKET_STATE_DIR}/<name>.pid` and calls
`os.kill(pid, 0)` (via `_service_live`, `pocket-mcp.py:395-409`) — no HTTP probe of any kind, and no read of
the `*.degraded` crash-loop markers the admin panel's own `gather_health()` treats as authoritative over a
momentary pgrep/pidfile hit (`admin/app.py:1099-1103`: *"A crash-looping service is NOT healthy even if pgrep
caught it mid-respawn"*). This spec's `pocket_health` closes both gaps — see §14 finding 2 for the exact
citation trail.

**Scope of the HTTP-probe addition is deliberately bounded.** The admin panel's full probe list
(`_build_http_probes()`, `admin/app.py:848-897`) and process list (`_build_health_procs()`,
`admin/app.py:904-1006`) are each ~15 `ENABLE_*`-conditional branches, hand-maintained, with zero shared code
between them and `pocket-mcp.py`. Porting the *entire* conditional list into a fourth hand-maintained copy
(after `lib-sites.sh`/`admin/app.py`/the new sites constants from AD-3) would make the duplication-contract
problem materially worse for marginal benefit, since most of those probes are per-optional-app liveness
checks an operator can already get from `pocket_status`/`pocket_list_services`. **Decision:** `pocket_health`
gains exactly the three **unconditional** probes admin already runs regardless of which apps are enabled
(`admin/app.py:849-856`) — conduwuit direct, matrix via Caddy, and the admin panel's own `/login` — plus
degraded-marker awareness for every currently-supervised service (reusing the existing
`_supervised_services()` closed-world set, `pocket-mcp.py:380-392`, no new conditional list required for
that half). Full per-app HTTP-probe parity is left as an explicit open question (§13, OQ-2) with a
recommendation to factor `_build_http_probes()`/`_build_health_procs()` into a small shared module both
`admin/app.py` and `pocket-mcp.py` import, rather than adding a third copy piecemeal.

### AD-8 — `ALLOWED_LOGS` widened with named, justified additions; still a closed allowlist

The shipped default (`_DEFAULT_ALLOWED_LOGS`, `pocket-mcp.py:202-205`) is 8 basenames. This spec adds 6,
every one an actual file a supervised service or a detached script writes (verified by grepping
`${POCKET_LOG_DIR}` usage across `scripts/`, not guessed):

| Added basename | Why | Evidence |
|---|---|---|
| `metrics-sampler.log` | the new `pocket_metrics` tool's backing sampler's own operational log (distinct from the *data* file, `POCKET_METRICS_LOG`) | supervised via `supervise metrics-sampler -- …` → `$POCKET_LOG_DIR/metrics-sampler.log` (`scripts/lib/common.sh:143`) |
| `user-filter.log` | security-relevant moderation subsystem, same class as `honeypot.log` (already default) | `scripts/user-filter/user-filter.py` supervised entry |
| `media-filter.log` | same rationale as `user-filter.log` | `scripts/media-filter/media-filter.py` supervised entry |
| `honeypot-watcher.log` | the honeypot **process's** own log — distinct from `honeypot.log`, which is the JSONL **event ledger** `pocket_honeypot_recent` already reads (`pocket-mcp.py:708`) | `scripts/honeypot/honeypot-watcher.py` supervised entry |
| `adminweb-async.log` | the panel's shared sink for every detached panel action (full-backup, offsite-push, catalog installs, apply-vhost) — an operator diagnosing "why didn't my panel action finish" needs this, and it's the SAME file for every one of those (`admin/app.py:590`) | `admin/app.py:579-600` (`run_script_detached`) |
| `mcp-async.log` | this spec's own new detached-launch sink (AD-2) — `pocket_site_status` reads the **job-specific** log, but a launch failure *before* the job even starts (e.g. `site-deploy.sh` not found) only ever lands here | `_MCP_ASYNC_LOG` (AD-2) |

The allowlist stays closed-world by construction (`_parse_allowed_logs`, `pocket-mcp.py:208-218`, unchanged)
and remains operator-extensible via `MCP_ALLOWED_LOGS`. Per-job deploy logs (`site-deploy-<job>.log`) are
**not** added to this list — they have a dynamic basename (one per job) that a fixed allowlist cannot express
safely; they are read exclusively through `pocket_site_status` (§6), which validates the `job_id` shape
before ever building the path, the same realpath-containment discipline `pocket_logs` already uses
(`pocket-mcp.py:596-601`).

### AD-9 — `ENABLE` dict grows four keys already read by every other surface in this repo

`pocket-mcp.py`'s `ENABLE` dict (`pocket-mcp.py:179-198`) is missing four flags `admin/app.py`'s equivalent
dict already carries (`admin/app.py:114-154`): `sites` (`ENABLE_SITES`), `user-admin` (`ENABLE_USER_ADMIN`),
`metrics` (`ENABLE_METRICS`), `offsite` (`ENABLE_OFFSITE_BACKUP`). All four gate registration of tools in
this spec (sites tools need `ENABLE["sites"]`; user-mgmt tools need `ENABLE["user-admin"]`; `pocket_metrics`
needs `ENABLE["metrics"]`; `pocket_offsite_push` needs `ENABLE["offsite"]`) and no new `.env` key is
introduced — every flag already exists and is already read by `admin/app.py`'s installer-driven
`_flag()`/`_env()` pattern (identical helper already present in `pocket-mcp.py:113-114`).

### AD-10 — the `mcp` package is absent from CI's test job; new tests must skip cleanly, and the gap is flagged

`.github/workflows/ci.yml`'s `tests` job installs `pytest flask segno` (`ci.yml:70`) and never installs
`mcp` — meaning `scripts/mcp/pocket-mcp.py`'s unconditional `from mcp.server.fastmcp import FastMCP`
(`pocket-mcp.py:68`) would hard-fail an import in CI today. `tests/test_panel_sites.py` already established
the pattern for exactly this situation with Flask: `flask = pytest.importorskip("flask")`
(`tests/test_panel_sites.py:34`), so the module skips cleanly wherever the dependency is absent instead of
erroring the whole run. This spec's new test module (§12) follows the identical pattern:
`pytest.importorskip("mcp")` before importing `pocket-mcp.py`. **This means the new tests will SKIP, not
run, in CI as it is configured today** — flagged here exactly the way SPEC-SITES-PANEL AD-10 flagged the
gunicorn-timeout companion change: implementing M3 needs a follow-up one-line addition to
`.github/workflows/ci.yml:70` (`pip install pytest flask segno mcp==1.28.0 uvicorn==0.49.0`, pinned to the
exact versions `scripts/mcp/requirements.txt` already ships) so the new suite actually executes instead of
silently skipping forever. `mcp`'s `pydantic-core` dependency has prebuilt `manylinux`/x86_64 wheels for a
GitHub Actions `ubuntu-latest` runner (the Termux/aarch64 build caveat in `docs/MCP.md`'s "Build caveat" note
is a phone-only concern), so this addition should not meaningfully slow the CI job or need a Rust toolchain.

## 4. Tool inventory — the complete M3 tier tables

**NEW** = added by this spec. **MODIFIED** = shipped tool, behavior/config changed by this spec. Everything
else is unchanged from `docs/MCP_SERVER_SPEC.md` §8.

### 4.1 READ tier (always on when `ENABLE_MCP=true`)

| Tool | Status | Gate | Wraps |
|---|---|---|---|
| `pocket_status` | unchanged | — | `ops/status.sh` |
| `pocket_health` | **MODIFIED** (AD-7) | — | pidfiles + degraded markers + 3 core HTTP probes |
| `pocket_list_services` | unchanged | — | `${POCKET_STATE_DIR}/*.cmd` |
| `pocket_logs` | **MODIFIED** (AD-8, wider default allowlist) | — | tail an allowlisted log |
| `pocket_config` | **MODIFIED** (new `ENABLE` keys surfaced, AD-9) | — | `.env` `ENABLE_*` + non-secret keys |
| `pocket_backups_list` | unchanged | — | `BACKUP_DIR` listing |
| `pocket_honeypot_recent` | unchanged | `ENABLE["honeypot"]` | honeypot ledger |
| `pocket_matrix_users` | unchanged | — | Matrix CS-API (read-only) |
| `pocket_restore_describe` | unchanged | — | `ops/restore.sh` dry-run |
| `pocket_doctor` | **NEW** (§7.1) | — | `ops/doctor.sh` |
| `pocket_metrics` | **NEW** (§7.2) | `ENABLE["metrics"]` | `POCKET_METRICS_LOG` ring file |
| `pocket_problems` | **NEW** (§7.3) | — | degraded + down + failing-probe summary |
| `pocket_audit_recent` | **NEW** (§7.4) | — | `admin-audit.log` tail |
| `pocket_sites_list` | **NEW** (§5.1) | `ENABLE["sites"]` | `.registry.json` (direct read, AD-3) |
| `pocket_site_releases` | **NEW** (§5.2) | `ENABLE["sites"]` | `.registry.json` (direct read, AD-3) |
| `pocket_site_status` | **NEW** (§5.4) | `ENABLE["sites"]` | `site-job-<id>.json` (direct read) |

### 4.2 OPERATE tier (`MCP_ALLOW_OPERATE=true`)

| Tool | Status | Gate | Wraps |
|---|---|---|---|
| `pocket_restart_service` | unchanged | — | `ops/restart.sh <svc>` |
| `pocket_backup_db` | unchanged | — | `ops/backup-db.sh` |
| `pocket_backup_all` | unchanged (AD-2: stays synchronous) | — | `ops/backup-all.sh` |
| `pocket_mint_invite_token` | unchanged (AD-6: also covers "invite") | — | `bootstrap/mint-invite-token.sh` |
| `pocket_rotate_registration_token` | unchanged | — | `ops/rotate-registration-token.sh` |
| `pocket_restart_stack` | **NEW** (§7.5) | — | `start-stack.sh --restart` |
| `pocket_rotate_backups` | **NEW** (§7.6) | — | `ops/rotate-backups.sh` |
| `pocket_offsite_push` | **NEW** (§7.7, synchronous — AD-2) | `ENABLE["offsite"]` | `ops/offsite-push.sh` |
| `pocket_user_create` | **NEW** (§7.8) | `ENABLE["user-admin"]` | `ops/user-create.sh` |
| `pocket_user_reset_password` | **NEW** (§7.8) | `ENABLE["user-admin"]` | `ops/user-reset-password.sh` |
| `pocket_user_suspend` | **NEW** (§7.8) | `ENABLE["user-admin"]` | `ops/user-suspend.sh` |
| `pocket_user_unsuspend` | **NEW** (§7.8) | `ENABLE["user-admin"]` | `ops/user-unsuspend.sh` |
| `pocket_site_deploy` | **NEW** (§5.3, detached — AD-2) | `ENABLE["sites"]` | `sites/site-deploy.sh` |
| `pocket_site_rollback` | **NEW** (§5.5) | `ENABLE["sites"]` | `sites/site-rollback.sh` |

### 4.3 DANGER tier (`MCP_ALLOW_DANGER=true` + per-call typed confirm)

| Tool | Status | Gate | Confirm shape |
|---|---|---|---|
| `pocket_panic_soft` | unchanged | — | fixed phrase = tool name |
| `pocket_panic_hard` | unchanged | — | fixed phrase = tool name |
| `pocket_user_deactivate` | **NEW** (§7.9) | `ENABLE["user-admin"]` | `confirm == user` (AD-4) |
| `pocket_site_delete` | **NEW** (§5.6) | `ENABLE["sites"]` | `confirm == site` (AD-4) |

## 5. New sites tool group

### 5.1 `pocket_sites_list() -> str`

```python
if ENABLE["sites"]:

    @mcp.tool()
    def pocket_sites_list() -> str:
        """List every deployed Pocket Pages site with its active release, release
        count, size, and URL. Reads .registry.json directly (AD-3) — the same
        derived-state file the panel's Sites page and `site-list.sh --json` both
        read; a missing/corrupt registry degrades to an empty list rather than
        raising."""
        _audit("pocket_sites_list")
        try:
            with open(SITES_REGISTRY) as f:
                raw = f.read()
            json.loads(raw)  # validate before returning malformed JSON to a client
            return raw
        except Exception:
            return json.dumps({"version": 1, "sites": {}}, indent=2)
```

### 5.2 `pocket_site_releases(site: str) -> str`

```python
    @mcp.tool()
    def pocket_site_releases(site: str) -> str:
        """Release history + metadata for ONE site (created/updated/active_release/
        releases/build/bytes/url), straight from the registry. `site` must be a
        currently-registered site name — closed-world, like the `service` argument
        of pocket_restart_service (pocket-mcp.py:758-761)."""
        _audit("pocket_site_releases", site=site)
        reg = _sites_registry()
        entry = reg.get("sites", {}).get(site)
        if entry is None:
            raise ValueError(
                f"no such site {site!r}; known sites: {sorted(reg.get('sites', {}))}")
        return json.dumps(entry, indent=2)
```

`_sites_registry()` is a tiny shared helper (`json.load` + the same graceful-degrade as 5.1) both this tool
and `pocket_site_rollback` use.

### 5.3 `pocket_site_deploy(site: str, staged_path: str, build: str = "none") -> str`

```python
    @mcp.tool()
    def pocket_site_deploy(site: str, staged_path: str, build: str = "none") -> str:
        """Deploy an ALREADY-STAGED artifact (a directory or a .zip placed under
        SITES_ROOT/.staging by some other channel — scp/rsync, or the panel's own
        upload) as a new release of `site`. Does NOT accept file content as an
        argument (AD-1) — this tool only points the pipeline at a path.

        Returns immediately with a job id; the deploy runs DETACHED (it can take
        up to SITES_BUILD_TIMEOUT for the hugo/node build tiers) — poll progress
        with pocket_site_status(job_id)."""
        name = (site or "").strip()
        if not SITE_SUB_RE.fullmatch(name) or name in SITE_RESERVED:
            raise ValueError(f"invalid or reserved site name: {site!r}")
        if build not in ("none", "hugo", "node"):
            raise ValueError("build must be one of: none, hugo, node")
        staging_root = os.path.realpath(SITES_STAGING)
        real_path = os.path.realpath(staged_path)
        if real_path != staging_root and not real_path.startswith(staging_root + os.sep):
            raise ValueError(
                f"staged_path must resolve inside {SITES_STAGING} "
                f"(stage the artifact there first — MCP never carries file content, AD-1)")
        if not os.path.exists(real_path):
            raise ValueError(f"staged_path does not exist: {staged_path!r}")
        job_id = _new_job_id()
        _audit("pocket_site_deploy", site=name, staged_path=staged_path, build=build, job=job_id)
        ok = _run_ops_detached("sites/site-deploy.sh", name, real_path,
                                "--build", build, "--job", job_id)
        if not ok:
            raise RuntimeError("could not launch the deploy — see " +
                                os.path.join(LOGS, _MCP_ASYNC_LOG))
        return (f"deploy started: site={name} build={build} job={job_id} — "
                f"poll pocket_site_status({job_id!r}) for progress")
```

`_new_job_id()` mints the same `<UTC-ts>-<4hex>` shape `lib-sites.sh`'s `new_job_id()` does
(`lib-sites.sh:141`), using `time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(2)` —
the identical one-liner the panel's upload route already uses (`admin/app.py:3131`). Minting the id in
Python (rather than letting `site-deploy.sh` mint its own and parsing it back out of stdout) means the tool
can return the job id **before** the script has necessarily even started running — see §6 for how
`pocket_site_status` handles that race.

**Widening beyond the program plan's literal two-argument sketch:** the plan names
`pocket_site_deploy(site, staged_path)`; this design adds an optional `build` parameter (default `"none"`,
matching `site-deploy.sh`'s own default). Omitting it would make the MCP surface unable to reach the hugo/node
build tiers `site-deploy.sh` already fully supports (`scripts/sites/site-deploy.sh:153-286`) — a real
capability gap with no offsetting safety benefit, since the value is validated against a fixed 3-item enum
before it ever reaches argv. Called out explicitly per the task's instruction to flag every deviation from
the plan sketch.

### 5.4 `pocket_site_status(job_id: str) -> str`

```python
    @mcp.tool()
    def pocket_site_status(job_id: str) -> str:
        """Poll a site job's state (deploy/rollback/delete). Returns the job
        record (job/kind/site/state/release/started/ended/error) plus a short
        redacted tail of the job's own log, when one exists.

        A job id that doesn't have a state file YET (the brief window between
        pocket_site_deploy returning and the detached process actually calling
        job_start()) reports state="running" rather than raising — mirrors the
        panel's own /sites/job/<id> behavior exactly (admin/app.py:3244-3248)."""
        jid = (job_id or "").strip()
        if not _SITE_JOB_RE.fullmatch(jid):
            raise ValueError(f"invalid job id: {job_id!r}")
        _audit("pocket_site_status", job=jid)
        state_path = os.path.join(STATE, f"site-job-{jid}.json")
        try:
            with open(state_path) as f:
                doc = json.load(f)
        except Exception:
            doc = {"job": jid, "state": "running"}
        log_path = os.path.join(LOGS, f"site-deploy-{jid}.log")
        tail = _tail_file(log_path, 20)
        if not tail.startswith("(no such log") and not tail.startswith("(cannot read log"):
            doc["log_tail"] = _redact(tail)
        return json.dumps(doc, indent=2)
```

Reuses `_tail_file` (`pocket-mcp.py:361-377`) and `_redact` (`pocket-mcp.py:260-279`) unmodified — the job
log can contain build-tool output (`npm`, `hugo`) that in principle could echo an environment variable; the
same redaction discipline `pocket_logs` already applies is worth the one extra pass here even though job
logs are lower-risk than arbitrary service logs.

### 5.5 `pocket_site_rollback(site: str, release: str = "") -> str`

```python
    @mcp.tool()
    def pocket_site_rollback(site: str, release: str = "") -> str:
        """Instant pointer-swap rollback for `site` — no rebuild, no copy (AD-4 of
        SPEC-SITES-PIPELINE). `release` is optional; empty means "the release
        immediately before the current one" (site-rollback.sh's own default,
        scripts/sites/site-rollback.sh:44-50). Synchronous — a rollback is a
        single rename(2), never worth a detached job (mirrors the panel's AD-5,
        SPEC-SITES-PANEL.md:137-143)."""
        name = (site or "").strip()
        if not SITE_SUB_RE.fullmatch(name):
            raise ValueError(f"invalid site name: {site!r}")
        reg = _sites_registry()
        entry = reg.get("sites", {}).get(name)
        if entry is None:
            raise ValueError(f"no such site {name!r}")
        rel = (release or "").strip()
        if rel and rel not in entry.get("releases", []):
            raise ValueError(f"unknown release {rel!r} for site {name!r}; "
                              f"known: {entry.get('releases', [])}")
        _audit("pocket_site_rollback", site=name, release=rel or "previous")
        args = [name] + ([rel] if rel else [])
        rc, out = _run_ops("sites/site-rollback.sh", *args, timeout=60)
        if rc != 0:
            raise RuntimeError(f"site-rollback.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or f"rolled back {name}"
```

### 5.6 `pocket_site_delete(site: str, confirm: str) -> str`

```python
    if MCP_ALLOW_DANGER:

        @mcp.tool()
        def pocket_site_delete(site: str, confirm: str) -> str:
            """BREAK-GLASS: permanently delete a site and ALL its release history —
            not just the live release. Not reversible. Requires `confirm` to
            exactly equal `site` (AD-4) — the site name itself, not a fixed phrase,
            because this action takes a target and a fixed phrase would authorize
            deleting ANY site."""
            name = (site or "").strip()
            if not SITE_SUB_RE.fullmatch(name):
                raise ValueError(f"invalid site name: {site!r}")
            reg = _sites_registry()
            if name not in reg.get("sites", {}):
                raise ValueError(f"no such site {name!r} — nothing to delete")
            _require_confirm(confirm, name)               # raises before any action
            _audit("pocket_site_delete", site=name, confirmed=True)
            rc, out = _run_ops("sites/site-delete.sh", name, "--yes", timeout=60)
            if rc != 0:
                raise RuntimeError(f"site-delete.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"deleted {name}"
```

## 6. The job-id + status-poll pattern (shared design)

Only one tool family uses this pattern in M3: `pocket_site_deploy` → `pocket_site_status`. The shape is
intentionally minimal so it generalizes cleanly if a future milestone adds a second async tool:

1. The mutating tool validates everything it can validate synchronously (name, path containment, enum
   values), mints a job id **in Python** (not by parsing script output), audits the call, then launches the
   backing script detached and returns the job id immediately.
2. The backing script owns the job **state file** (`lib-sites.sh:job_start`/`job_done`/`job_fail`,
   already shipped, AD-6 of SPEC-SITES-PIPELINE) — the MCP layer never writes it.
3. A read-only status tool validates the job id shape, reads the state file (tolerating "doesn't exist yet"
   as `state: "running"`, matching the panel's shipped behavior exactly, `admin/app.py:3244-3248`), and
   optionally attaches a redacted log tail.
4. There is no push notification — the MCP client polls. `docs/MCP.md` (§10 below) should recommend a
   3-5 second poll interval, matching the panel's own SSE-fallback poll cadence (`admin/app.py`'s
   `pollJob()`, 2000ms) — fast enough to feel responsive, slow enough not to matter against
   `MCP_RATE_LIMIT`'s default `60/min` on the HTTP transport (§9's threat-model row expands on this).

## 7. Parity tools

### 7.1 `pocket_doctor() -> str`

```python
@mcp.tool()
def pocket_doctor() -> str:
    """Read-only preflight/self-test (storage tiers, Termux integration, service
    liveness, DEGRADED markers). Never changes anything. Wraps ops/doctor.sh
    (--strict is deliberately never passed — MCP always gets the advisory,
    always-exit-0 report; the exit code is not useful to an MCP client, the TEXT
    is)."""
    _audit("pocket_doctor")
    rc, out = _run_ops("ops/doctor.sh", timeout=60)
    return _redact(out) if out.strip() else f"doctor.sh produced no output (rc={rc})"
```

`doctor.sh` already never echoes secret values by design (`scripts/ops/doctor.sh:9`, "it never prints secret
values — only 'set' / 'MISSING' / 'placeholder'"), so `_redact()` here is belt-and-suspenders, matching every
other `_run_ops` call's convention.

### 7.2 `pocket_metrics(samples: int = 60) -> str`

```python
METRICS_LOG = _env("POCKET_METRICS_LOG") or os.path.join(
    os.path.expanduser("~"), ".pocket", "metrics", "metrics.jsonl")   # mirrors admin/app.py:70-71
_METRICS_MAX_SAMPLES = 500   # bound a client from asking for the whole 4-day ring

if ENABLE["metrics"]:

    @mcp.tool()
    def pocket_metrics(samples: int = 60) -> str:
        """Recent device/stack metrics (cpu/mem/load/disk/temp/battery/degraded
        count) sampled by ops/metrics-sampler.py. Returns the last `samples`
        JSONL records (bounded) plus a min/avg/max/current summary per field —
        the same numbers admin/app.py's /metrics page cards show
        (admin/app.py:3513-3530), as structured JSON instead of HTML."""
        _audit("pocket_metrics", samples=samples)
        try:
            n = int(samples)
        except (TypeError, ValueError):
            raise ValueError("samples must be an integer")
        n = max(1, min(n, _METRICS_MAX_SAMPLES))
        try:
            with open(METRICS_LOG) as f:
                lines = f.readlines()[-n:]
        except FileNotFoundError:
            return json.dumps({"samples": [], "note": "no metrics recorded yet"}, indent=2)
        recs = []
        for ln in lines:
            try:
                recs.append(json.loads(ln))
            except Exception:
                continue
        fields = ("cpu", "mem", "swap", "l1", "disk", "temp", "batt", "deg")
        summary = {}
        for field in fields:
            vals = [r[field] for r in recs if isinstance(r.get(field), (int, float))]
            if vals:
                summary[field] = {"current": vals[-1], "min": min(vals),
                                   "avg": round(sum(vals) / len(vals), 2), "max": max(vals)}
        return json.dumps({"summary": summary, "sample_count": len(recs),
                            "samples": recs}, indent=2)
```

### 7.3 `pocket_problems() -> str`

```python
@mcp.tool()
def pocket_problems() -> str:
    """Everything currently wrong, and nothing else: crash-looping (DEGRADED)
    services, DOWN services, and failing HTTP probes. Empty result means "all
    green" — mirrors admin/app.py's /problems page (admin/app.py:3626-3686) as
    structured JSON instead of HTML cards."""
    _audit("pocket_problems")
    degraded, down = [], []
    for name in sorted(_supervised_services()):
        marker = _degraded_marker(name)
        if marker:
            degraded.append({"service": name, "detail": marker})
            continue
        alive, _pid = _service_live(name)
        if not alive:
            down.append(name)
    probe_fail = [p for p in (_probe(p) for p in _CORE_HTTP_PROBES) if not p["ok"]]
    if not (degraded or down or probe_fail):
        return json.dumps({"ok": True, "message": "no problems"}, indent=2)
    return json.dumps({"ok": False, "degraded": degraded, "down": down,
                        "failing_probes": probe_fail}, indent=2)
```

### 7.4 `pocket_audit_recent(limit: int = 50) -> str`

```python
@mcp.tool()
def pocket_audit_recent(limit: int = 50) -> str:
    """Recent audit-log entries from the SAME admin-audit.log both the panel and
    this server append to (pocket-mcp.py:130-131) — surfaces BOTH panel-sourced
    and MCP-sourced actions, since it's one shared trail by design. Panel-sourced
    entries carry the operator's own client ip/user-agent (admin/app.py:408-421)
    — that's the operator's own metadata, not a third party's, so it is not
    redacted, only capped."""
    _audit("pocket_audit_recent", limit=limit)
    try:
        n = int(limit)
    except (TypeError, ValueError):
        raise ValueError("limit must be an integer")
    n = max(1, min(n, 500))
    lines = _read_file(AUDIT_LOG, default="").splitlines()[-n:]
    out = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except Exception:
            continue
        for k, v in list(rec.items()):
            if isinstance(v, str):
                rec[k] = _redact(v)
        out.append(rec)
    return json.dumps(out, indent=2) if out else "no audit entries recorded"
```

### 7.5 `pocket_restart_stack() -> str`

```python
if MCP_ALLOW_OPERATE:

    @mcp.tool()
    def pocket_restart_stack() -> str:
        """Restart matrix + Caddy + cloudflared in order (apps untouched). Brief
        (tens of seconds) ingress outage while the tunnel reconnects; fully
        reversible. Wraps start-stack.sh --restart — the SAME script the panel's
        danger-zone 'restart stack' card runs (admin/app.py:165,
        DANGER_META['restart-stack']), but classified OPERATE here rather than
        DANGER: its impact (bounded, reversible, apps untouched,
        admin/app.py:290-299) is the whole-stack analogue of the already-OPERATE
        pocket_restart_service, not of panic-soft/hard's blast radius. The
        panel's own two-page confirm is a touchscreen fat-finger guard, not a
        statement about severity."""
        _audit("pocket_restart_stack")
        rc, out = _run_ops("start-stack.sh", "--restart", timeout=120)
        if rc != 0:
            raise RuntimeError(f"start-stack.sh --restart exited {rc}: {_redact(out)[-400:]}")
        return _redact(out) or "stack restart issued"
```

### 7.6 `pocket_rotate_backups() -> str`

```python
    @mcp.tool()
    def pocket_rotate_backups() -> str:
        """Prune backup snapshots to the configured retention (BACKUP_KEEP_DB /
        BACKUP_KEEP_ROOTFS). Safe to run any time — a no-op when nothing is due.
        Wraps ops/rotate-backups.sh."""
        _audit("pocket_rotate_backups")
        rc, out = _run_ops("ops/rotate-backups.sh", timeout=120)
        if rc != 0:
            raise RuntimeError(f"rotate-backups.sh exited {rc}: {_redact(out)[-400:]}")
        return _redact(out)
```

### 7.7 `pocket_offsite_push() -> str`

```python
    if ENABLE["offsite"]:

        @mcp.tool()
        def pocket_offsite_push() -> str:
            """Push already-ENCRYPTED backups to the configured S3-compatible
            bucket. Self-gated on ENABLE_OFFSITE_BACKUP and refuses (fail-closed)
            if backups aren't age-encrypted (scripts/ops/offsite-push.sh:46-49) —
            the S3 secret never touches this tool's return value. Synchronous
            (AD-2), bounded by OPS_TIMEOUT_DEFAULT."""
            _audit("pocket_offsite_push")
            rc, out = _run_ops("ops/offsite-push.sh", timeout=OPS_TIMEOUT_DEFAULT)
            if rc != 0:
                raise RuntimeError(f"offsite-push.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out)
```

### 7.8 User management (create / reset-password / suspend / unsuspend)

All four share validation (`_VALID_LOCALPART`/`_VALID_MXID`, ported verbatim from `admin/app.py:3695-3696`)
and are thin — one per script, matching `ops/user-*.sh`'s own one-op-per-script shape:

```python
    _VALID_LOCALPART = re.compile(r"^[a-z0-9][a-z0-9._=-]{0,63}$")
    _VALID_MXID = re.compile(r"^@[a-z0-9._=/+-]+:[A-Za-z0-9.:-]+$")

    def _valid_user_target(val, allow_mxid):
        v = (val or "").strip()
        if _VALID_LOCALPART.fullmatch(v):
            return v
        if allow_mxid and _VALID_MXID.fullmatch(v):
            return v
        raise ValueError(f"invalid user {val!r} (want a localpart, or @user:server where noted)")

    if ENABLE["user-admin"]:

        @mcp.tool()
        def pocket_user_create(localpart: str) -> str:
            """Create a local Matrix user. The server GENERATES the password and
            returns it in its reply — the tool's return value therefore CAN
            contain a fresh credential (unlike every other tool here); it also
            lands in the admin command room's history (ops/user-create.sh:8,
            docs/USERS.md) regardless of how it was triggered."""
            u = _valid_user_target(localpart, allow_mxid=False)
            _audit("pocket_user_create", localpart=u)
            rc, out = _run_ops("ops/user-create.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-create.sh exited {rc}: {_redact(out)[-400:]}")
            return out   # NOT _redact()'d — see the docstring; the generated password IS the payload

        @mcp.tool()
        def pocket_user_reset_password(localpart: str) -> str:
            """Reset a local user's password; the NEW password is generated and
            returned (same caveat as pocket_user_create)."""
            u = _valid_user_target(localpart, allow_mxid=False)
            _audit("pocket_user_reset_password", localpart=u)
            rc, out = _run_ops("ops/user-reset-password.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-reset-password.sh exited {rc}: {_redact(out)[-400:]}")
            return out

        @mcp.tool()
        def pocket_user_suspend(user: str) -> str:
            """Suspend an account (read-only). Reversible with pocket_user_unsuspend.
            `user` is a localpart or a full @user:server MXID."""
            u = _valid_user_target(user, allow_mxid=True)
            _audit("pocket_user_suspend", user=u)
            rc, out = _run_ops("ops/user-suspend.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-suspend.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"suspended {u}"

        @mcp.tool()
        def pocket_user_unsuspend(user: str) -> str:
            """Lift a suspension."""
            u = _valid_user_target(user, allow_mxid=True)
            _audit("pocket_user_unsuspend", user=u)
            rc, out = _run_ops("ops/user-unsuspend.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-unsuspend.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"unsuspended {u}"
```

`pocket_user_create`/`pocket_user_reset_password` deliberately do **not** call `_redact()` on their return
value — the generated password *is* the useful payload (the same design already accepted for
`pocket_mint_invite_token`, `pocket-mcp.py:802`, "its purpose is to be shared, so it IS returned"). This is
worth a one-line callout in the security model (§9) since it's the second tool family (after invite-mint)
that deliberately returns a fresh credential over MCP.

### 7.9 `pocket_user_deactivate(user: str, confirm: str) -> str`

```python
    if MCP_ALLOW_DANGER and ENABLE["user-admin"]:

        @mcp.tool()
        def pocket_user_deactivate(user: str, confirm: str) -> str:
            """BREAK-GLASS: deactivate (close) an account — effectively
            irreversible; re-enabling means creating the account again
            (ops/user-deactivate.sh:6-8). Requires `confirm` to exactly equal the
            `user` value passed to THIS call (AD-4) — a direct port of the panel's
            shipped retype-the-exact-id behavior (admin/app.py:3703, :3816-3820),
            not a new design for this tool."""
            u = _valid_user_target(user, allow_mxid=True)
            _require_confirm(confirm, user)   # compares against the RAW argument,
                                               # exactly like admin/app.py:3817
                                               # compares against `val`, pre-expansion
            _audit("pocket_user_deactivate", user=u, confirmed=True)
            rc, out = _run_ops("ops/user-deactivate.sh", u, timeout=90)
            if rc != 0:
                raise RuntimeError(f"user-deactivate.sh exited {rc}: {_redact(out)[-400:]}")
            return _redact(out) or f"deactivated {u}"
```

## 8. Resources and prompts

### 8.1 `pocket://sites`

```python
@mcp.resource("pocket://sites")
def sites_resource() -> str:
    """The full site registry (same as pocket_sites_list), as a resource."""
    if not ENABLE["sites"]:
        return json.dumps({"version": 1, "sites": {}, "note": "sites module disabled"})
    try:
        with open(SITES_REGISTRY) as f:
            return f.read()
    except Exception:
        return json.dumps({"version": 1, "sites": {}})
```

### 8.2 `pocket://metrics`

```python
@mcp.resource("pocket://metrics")
def metrics_resource() -> str:
    """The last 60 metric samples' summary (same shape as pocket_metrics(60)),
    as a resource — for a client that wants a cheap ambient status check
    without an explicit tool call."""
    if not ENABLE["metrics"]:
        return json.dumps({"note": "metrics module disabled"})
    return pocket_metrics(60)   # reuses the tool function directly — same logic, no duplication
```

### 8.3 `deploy_report(site: str)` prompt

```python
@mcp.prompt(title="Deploy report")
def deploy_report(site: str) -> str:
    """Walk the model through summarizing one site's deploy state."""
    return (
        f"Produce a concise deploy report for the Pocket Pages site '{site}' on "
        f"this pocket-homeserver:\n"
        f"1. Call pocket_site_releases('{site}') for its current state (active "
        f"release, build tier, size, URL, release count).\n"
        f"2. If the operator mentions an in-flight or recent job id, call "
        f"pocket_site_status(job_id) and report its state/error.\n"
        f"3. Summarize: is the site live, when was it last deployed, how many "
        f"releases of history exist, and is there anything that looks stuck or "
        f"failed.\n"
        f"4. Do not call pocket_site_deploy, pocket_site_rollback, or "
        f"pocket_site_delete without explicit operator approval — this prompt is "
        f"for reporting, not for acting."
    )
```

## 9. Configuration

**No new `.env` keys.** Every gate this spec needs (`ENABLE_SITES`, `ENABLE_USER_ADMIN`, `ENABLE_METRICS`,
`ENABLE_OFFSITE_BACKUP`, `MCP_ALLOW_OPERATE`, `MCP_ALLOW_DANGER`, `MCP_ALLOWED_LOGS`) already exists and is
already read by some other installer; `pocket-mcp.py`'s `ENABLE` dict just needs the four additional keys
(AD-9). The only config-shaped change is the widened `_DEFAULT_ALLOWED_LOGS` default (AD-8, a code constant,
not a new key).

## 10. Documentation updates required

Not applied by this spec (single-file-only scope), but the M3 implementation must update:

- **`docs/MCP_SERVER_SPEC.md`**: §4 background table gains the sites pipeline + `ops/doctor.sh`/
  `metrics-sampler.py`/`ops/rotate-backups.sh`/`ops/offsite-push.sh`/`ops/user-*.sh` rows; §8.1/§8.2/§8.3
  tables gain every new tool from §4 of this spec; the §8.1 `pocket_health` row must be corrected to match
  what's actually now true (it was already inaccurate for the shipped v0.3.0 tool, per AD-7); a new §8.x
  documents the job-id + status-poll pattern (§6); §11 config table — no new keys, but the doc should note
  the sites/user-admin/metrics/offsite tools inherit their app's own `ENABLE_*` flag; §13 gets an M3
  decisions entry once approved.
- **`docs/MCP.md`**: the "Tool reference" tables mirror §4 of this spec; a new "Deploying a site over MCP"
  how-to section must explain the out-of-band staging step from AD-1 (how an operator gets a zip into
  `.staging/` before calling `pocket_site_deploy` — e.g. `scp site.zip phone:…/sites/.staging/`); the
  Configuration reference table gets the four `ENABLE_*` cross-references from AD-9; Troubleshooting gains an
  entry for "a sites/user-admin/metrics/offsite tool is missing from `tools/list`" (its module `ENABLE_*` is
  off, same pattern the existing honeypot entry already documents).
- **`docs/SITES.md`**: gains a short "MCP" cross-reference next to the existing panel section, pointing at
  the new how-to in `docs/MCP.md`.
- **`CHANGELOG.md`**: `### Added` entry for the M3 tool group once implemented.

## 11. Threat model

| Threat | Mitigation |
|---|---|
| Argv injection via `site` | `SITE_SUB_RE` + `SITE_RESERVED` checked before any argv is built (AD-5); the underlying script's own `validate_site_name()` (`lib-sites.sh:94-116`) is the authoritative last-mile gate regardless of what the MCP layer already checked |
| Argv injection via `user`/`localpart` | `_VALID_LOCALPART`/`_VALID_MXID`, ported verbatim from the shipped panel regexes (`admin/app.py:3695-3696`), checked before argv; each `ops/user-*.sh` re-validates independently (e.g. `scripts/ops/user-suspend.sh:20-27`) |
| Staged-path containment (deploy) | `os.path.realpath(staged_path)` must resolve under `os.path.realpath(SITES_STAGING)` before the path is used (§5.3); `site-deploy.sh`'s own non-interactive containment check (`site-deploy.sh:87-94`) is always the live branch for an MCP-originated call (AD-5) since `_run_ops`/`_run_ops_detached` never attach a tty |
| Job-id validation | `_SITE_JOB_RE` (same shape as `RELEASE_ID_RE`, `lib-sites.sh:49`) checked with a whole-string `fullmatch` before any path is built, plus the existing realpath-containment pattern `pocket_logs` already uses (`pocket-mcp.py:596-601`) applied to the constructed job-log path |
| Confirm-string binding for parameterized DANGER tools | `pocket_site_delete`/`pocket_user_deactivate` require `confirm` to exactly equal the *target*, not a fixed phrase (AD-4) — closes the confused-deputy gap a fixed phrase would leave for a multi-target action; unparameterized DANGER tools (panic-soft/hard) keep their existing fixed-phrase check unchanged |
| Existence-check before DANGER dispatch | `pocket_site_delete` 404-equivalents (raises `ValueError`) for a site not already in the registry, mirroring the panel's "no probing for undeployed names" rule (`admin/app.py:3286-3288`) — a caller cannot use the confirm-required error path to fish for which site names exist |
| Detached-launch script allowlist | `_run_ops_detached` checks `_DETACHED_ALLOWLIST` (one entry: `sites/site-deploy.sh`) + the same realpath-under-`scripts/` containment `_run_ops` already uses (AD-2) — never a second general-purpose detached-anything primitive |
| Sites-reads bypass validation entirely (AD-3) | `pocket_sites_list`/`pocket_site_releases`/resource `pocket://sites` only ever `json.load()` a file under `SITES_ROOT` this server itself computed from `PD_BASE` (never a request-influenced path) — there is no argument that names a file for these three |
| Secret exfiltration via new tools | `pocket_doctor`/`pocket_rotate_backups`/`pocket_offsite_push`/`pocket_restart_stack`/suspend/unsuspend/deactivate all pass their output through `_redact()`; `pocket_user_create`/`pocket_user_reset_password` are the deliberate, documented exception (§7.8) — same accepted trade-off as the shipped `pocket_mint_invite_token` |
| Audit-log exposure via `pocket_audit_recent` | Surfaces the operator's OWN `ip`/`ua` metadata (panel-sourced entries, `admin/app.py:408-421`) — not a third party's; capped at 500 lines; every string field still passed through `_redact()` as defense-in-depth even though `ip`/`ua` don't match any secret pattern |
| Unauthorized mutation | every new OPERATE tool behind `MCP_ALLOW_OPERATE`; every new DANGER tool behind `MCP_ALLOW_DANGER` **and** its typed confirm; sites/user-admin/metrics/offsite tools ADDITIONALLY behind their own `ENABLE_*` flag — a tool is simply not registered (not present in `tools/list`) unless every applicable gate is on |
| Rate-limit interaction with polling | `pocket_site_status` polling is a normal `tools/call` on the HTTP transport and counts against `MCP_RATE_LIMIT` (default `60/min`, `pocket-mcp.py:972`) like any other call; `docs/MCP.md`'s new how-to (§10) recommends a 3-5s poll interval (≤20 calls/min for one in-flight deploy), well under the default cap; the **stdio** transport has no rate limiter at all (SSH is the boundary), so this only matters for remote HTTP clients |
| Detached job outliving the MCP server process | `start_new_session=True` (AD-2, matching `admin/app.py:2807`) — the deploy is not a child of the `pocket-mcp` process group, so it is unaffected by the (stdio-mode) server exiting once the tool call returns; the panel already relies on this same property for its own detached actions |

## 12. Test plan

**Unit (`tests/test_mcp.py`, new file — pytest, extending the existing suite's conventions):**

The whole module is gated `mcp = pytest.importorskip("mcp")` at the top (AD-10), following
`tests/test_panel_sites.py:34`'s exact pattern — this suite SKIPS cleanly today and starts running once
`.github/workflows/ci.yml`'s `tests` job installs `mcp==1.28.0` (the flagged companion change, AD-10).
Import strategy mirrors `test_panel_sites.py:42-89` (build fixture dirs, point every `POCKET_*`/`DATA_DIR`
seam at them via `os.environ`, import `scripts/mcp/pocket-mcp.py`, restore `os.environ`) rather than
`test_pipeline.py`'s real-subprocess approach — `pocket-mcp.py`'s tools are Python functions, so importing
and calling them directly is both faster and exercises the actual validation code, matching why
`test_panel_sites.py` imports `admin/app.py` instead of driving it over HTTP for its pure-logic tests.

- `SITE_SUB_RE`/`SITE_RESERVED` parity: two assertions — against `scripts/sites/reserved-subs.sh`'s
  `RESERVED_SUBS` (same subprocess-and-parse technique as `test_panel_sites.py:136-144`) **and** against
  `admin/app.py`'s own `SITE_RESERVED` constant (import both modules in the same test, assert the three sets
  are equal) — the three-way duplication contract from AD-3 needs a three-way test, not a two-way one.
- `_valid_user_target`: valid localpart, valid MXID (where `allow_mxid=True`), invalid localpart, MXID
  rejected where `allow_mxid=False`, embedded-newline/shell-metacharacter strings all rejected.
- `pocket_site_deploy`'s staging-containment check as a pure function test: a path inside `.staging/` (a
  tmp_path fixture standing in for it) accepted; a path with `..` that resolves outside rejected; a
  non-existent path rejected — mirrors `tests/test_pipeline.py`'s own
  `test_staging_containment_rejects_path_outside_staging`/`test_staging_containment_accepts_path_inside_staging`
  (`tests/test_pipeline.py:414-429`) but exercised against the **Python** check, not the bash one (the bash
  check is already covered by the existing pipeline suite; this suite covers the NEW Python-side check that
  runs before the script is even spawned).
- `pocket_site_status`: job file present → returns its contents + log tail; job file absent → returns
  `{"state": "running", ...}` without raising (the race-window behavior, §6); malformed job id (bad shape,
  path traversal attempt) → `ValueError` before any file is touched.
- `_require_confirm` reused with a dynamic phrase: `pocket_site_delete`-shaped call with `confirm != site`
  refused (raises, and — assert via a monkeypatched `_run_ops`/`_run_ops_detached` — the backing script is
  NEVER invoked); `confirm == site` proceeds to the (mocked) dispatch.
- `pocket_user_deactivate`: confirm checked against the raw `user` argument as typed (not the expanded MXID)
  — a test with `user="alice"` and `confirm="@alice:ci.example.org"` must be REFUSED (mirrors the panel's
  exact pre-expansion comparison, AD-4).
- `_run_ops_detached`: allowlist rejection for a non-allowlisted script name; realpath-escape rejection;
  successful launch writes to `LOGS/mcp-async.log` (assert the file is created/appended, using a trivial
  no-op fixture script instead of the real `site-deploy.sh`).
- `pocket_metrics`: empty ring file → the "no metrics recorded yet" branch; a small synthetic JSONL ring
  (3-4 records) → correct min/avg/max/current per field, and fields absent from every record are omitted
  from the summary (not reported as zero).
- `pocket_problems`: synthetic `POCKET_STATE_DIR` with one `.degraded` marker + one missing `.pid` file for
  a different supervised name → both appear in the correct bucket (`degraded` vs `down`), a fully-healthy
  fixture → `{"ok": true, ...}`.
- `ALLOWED_LOGS` default set: assert every new basename from AD-8's table is present, and the set stays a
  `frozenset`/`set` (never a list a caller could accidentally mutate).
- Widened `ENABLE` dict: assert the four new keys (`sites`, `user-admin`, `metrics`, `offsite`) are present
  and correctly read the corresponding `ENABLE_*` env var, using the same `os.environ` seam technique as the
  rest of the file.

**Needs the arm64 E2E (extends the M1/M2 harness — cannot be exercised on the laptop, no `proot-distro`):**

- `pocket_site_deploy` against a real fixture zip → job reaches `state: "done"` → `curl -H "Host:
  <site>.<domain>"` returns 200 with the deployed content (mirrors M1's own E2E assertion, applied via the
  MCP tool instead of the raw script).
- `pocket_site_rollback`/`pocket_site_delete` end-to-end against a real registry (rollback flips content
  with no non-200 window during the swap, matching M1's curl-loop assertion; delete → site 404s + registry
  entry gone).
- The hugo/node build tiers via `pocket_site_deploy(..., build="hugo"|"node")` — same "not exercised on a
  laptop, always run pre-release" caveat SPEC-SITES-PIPELINE §12 already states for the raw script.
- `pocket_user_create`/`reset_password`/`suspend`/`unsuspend`/`deactivate` against a real continuwuity admin
  command room (needs `ENABLE_USER_ADMIN` + a live homeserver — no laptop equivalent).
- `pocket_doctor`/`pocket_metrics`/`pocket_problems` against a real Termux environment (the storage-tier,
  Termux-integration, and `/proc`-reading checks these wrap are meaningless off-phone, same caveat
  `doctor.sh` itself already documents for its own "not on Termux" branches, `scripts/ops/doctor.sh:99-103`).
- HTTP-transport rate-limit interaction: a scripted `pocket_site_status` poll loop at the recommended 3-5s
  cadence against a real in-flight deploy, confirmed to stay under `MCP_RATE_LIMIT` for the deploy's full
  duration.

**Laptop smoke:**

- `python3 -c "import ast; ast.parse(open('scripts/mcp/pocket-mcp.py').read())"` — same check pattern
  `70-install-admin.sh:85` runs for `admin/app.py`; confirms the diff still parses (this already runs
  unconditionally via the CI `python (py_compile)` job, `ci.yml:41-53`, no change needed there).
- `shellcheck` — no shell files change in this milestone (pure Python + docs), so the existing `shellcheck`
  CI gate needs no new entries.

## 13. Open questions (for operator approval)

- **OQ-1**: AD-2 keeps `pocket_backup_all`/`pocket_offsite_push` synchronous rather than extending the job-id
  pattern to them (would need a new job-file convention in `scripts/ops/`, out of scope for an MCP-only
  spec). Accept as M3's boundary, with the job-file convention as a named follow-up? Or is a synchronous
  600s-bounded `pocket_offsite_push` acceptable indefinitely (network pushes rarely approach that ceiling in
  practice, since only already-encrypted deltas are uploaded)?
- **OQ-2**: AD-7 bounds `pocket_health`'s new HTTP-probe set to the 3 unconditional probes, deferring full
  per-app parity with `admin/app.py`'s `_build_http_probes()`/`_build_health_procs()` (~15 conditionals each)
  to avoid a third hand-maintained copy. Accept the bounded scope for M3, with a future shared-module
  refactor as the real fix? Or is per-app HTTP-probe parity valuable enough over MCP specifically (e.g. for
  an agent doing autonomous multi-app health triage) to warrant porting the full conditional list now,
  accepting the duplication?
- **OQ-3**: AD-6 declines to add `pocket_user_invite` since `pocket_mint_invite_token` already covers it.
  Should the DOCUMENTATION (§10, `docs/MCP.md`'s tool reference) still list `pocket_mint_invite_token` under
  a "user management" heading alongside the four new user tools (for discoverability), even though the
  underlying capability shipped in v0.3.0 under a different name?
- **OQ-4**: `pocket_metrics`'s `_METRICS_MAX_SAMPLES` cap (500) is a new invented constant with no existing
  precedent to match (unlike `LOG_TAIL_MAX`=2000 or the panel's 30-site health cap). Is 500 the right
  ceiling, or should it become an env-overridable `MCP_METRICS_MAX_SAMPLES` following the project's
  `SITES_*`/`MCP_*` naming convention (mirroring SPEC-SITES-PANEL OQ-2's identical question about its own
  30-site cap, resolved there as "keep the fixed cap, revisit only if it's actually hit")?

**Resolutions (2026-07-19, at approval):** OQ-1 — keep `pocket_backup_all`/`pocket_offsite_push`
synchronous; a `scripts/ops/` job-file convention is a named follow-up for a later milestone. OQ-2 —
bounded scope: the 3 unconditional core probes + degraded-marker awareness; per-app parity waits for the
shared probe-module refactor. OQ-3 — yes: `docs/MCP.md`'s tool reference lists `pocket_mint_invite_token`
under the user-management heading for discoverability. OQ-4 — keep the fixed 500-sample cap (the
SPEC-SITES-PANEL OQ-2 precedent: revisit only if it is actually hit).

## 14. Plan-sketch / shipped-code conflicts found during research (appendix)

Every place the program plan's M3 sketch (or a shipped doc) disagrees with the code as it actually ships —
each drove a design decision above, per §0's "the shipped code wins" rule. (Independently re-verified against
the working tree, 2026-07-18.)

1. **`pocket_user_invite` would be a redundant near-duplicate (→ AD-6).** The plan's user-mgmt list includes
   "invite", but `ops/user-invite.sh` is a two-line forward — `exec bash
   .../bootstrap/mint-invite-token.sh "${n}"` (`scripts/ops/user-invite.sh:23`) — to the exact script
   `pocket_mint_invite_token` already wraps (`pocket-mcp.py:787-802`). No second tool is added. The three
   layers also disagree on the count bound (shipped tool: 1-50, `pocket-mcp.py:797-798`; wrapper: `>= 1`
   with no ceiling, `user-invite.sh:18-21`; `mint-invite-token.sh:30`: no bound at all) — the shipped
   tool's 1-50 stands.
2. **`pocket_health`'s documented contract was never implemented (→ AD-7).** `docs/MCP_SERVER_SPEC.md:214`
   (and `docs/MCP.md:170`) claim "admin `HEALTH_PROCS` / HTTP checks"; the shipped function
   (`pocket-mcp.py:544-560`) only pidfile-checks and reads no `*.degraded` markers. M3 closes a
   pre-existing doc/implementation gap, not just adding scope — and §10 requires the spec-doc row be
   corrected at the same time.
3. **The plan's "job-id pattern for backup_all, site_deploy" cannot be applied uniformly (→ AD-2, OQ-1).**
   Only the sites module has a job-file convention (`job_start`/`job_done`/`job_fail`,
   `lib-sites.sh:342-427`); `grep -l 'job_start\|site-job-' scripts/ops/*.sh` matches nothing —
   `ops/backup-all.sh`/`ops/offsite-push.sh` just print to stdout and exit. `pocket_backup_all` (and the
   new `pocket_offsite_push`) stay synchronous; giving `scripts/ops/` its own job-file convention is a
   named follow-up, out of scope for an MCP-only milestone.
4. **CI's test job cannot import the MCP server today (→ AD-10).** `.github/workflows/ci.yml:70` installs
   `pytest flask segno` — no `mcp` — so the new `tests/test_mcp.py` must `pytest.importorskip("mcp")` and
   will SKIP in CI until the flagged companion change (`pip install ... mcp==1.28.0 uvicorn==0.49.0`,
   matching `scripts/mcp/requirements.txt`) lands with the M3 implementation.
5. **`_run_ops` does not explicitly pass `stdin=subprocess.DEVNULL` (→ AD-5).** The shipped call
   (`pocket-mcp.py:344`) inherits the server process's non-tty stdin — true in both transports today, but
   not the self-documenting guarantee the panel (`admin/app.py:2806`) and the test suite
   (`tests/test_pipeline.py:89`) both make explicit. M3 adds the explicit kwarg to `_run_ops` (one-line
   hardening of shipped code); `_run_ops_detached` (AD-2) ships with it from day one. The tty-gated
   staging-containment branch in `site-deploy.sh:87-94` depends on stdin being non-tty, so this guarantee
   deserves to be explicit.
