# SPEC-SITES-PANEL — Pocket Pages admin UI: Sites nav, drag-drop deploy, rollback, delete, health

**Status: APPROVED 2026-07-17 (operator) — including the two global admin changes (C2:
`MAX_CONTENT_LENGTH` cap §9 + gunicorn `--timeout` 60→180 AD-10) and the §15 edit to the shipped
`sites.caddy.tmpl`. OQ resolutions recorded at the end of §18.**

Milestone: M2 of the Pocket Pages program (the milestone immediately after SPEC-SITES-PIPELINE's M1).
Depends on: [SPEC-SITES-PIPELINE.md](SPEC-SITES-PIPELINE.md) — M1, APPROVED 2026-07-17 (pipeline, job model
AD-6, filesystem layout §4, registry schema §5, name validation §7).
Related (parallel/later): [SPEC-LANDING-SYNC.md](SPEC-LANDING-SYNC.md) (M2, ships alongside this spec),
SPEC-MCP-COMPLETION (M3), SPEC-DIFFERENTIATORS (M4).

---

## 0. Prerequisite check — M1 is code-complete and committed

M1 landed in full (public main commit `c1273c7`, 2026-07-17): installer, wildcard vhost template, the whole
pipeline (`site-deploy/rollback/list/delete/gc.sh` + `lib-sites.sh` + `reserved-subs.sh` +
`safe_extract.py`), 53 passing unit tests, and the CI pytest gate. The pipeline was additionally hardened
after this draft was first written — notably: whole-string `[[ =~ ]]` name/release/job-id validation
(newline-bypass fix), the BYO collision check against `byo-<name>.caddy` (the filename proxy-routes.sh
actually writes), `--job` id format validation in `site-deploy.sh`, `*.tmp*` release-dir filtering, and
fully implemented lazy Hugo/Node tool installs. This spec designs the panel **against the M1 contract as
shipped** (job files, registry schema, script CLI shapes); where a code sketch in this draft disagrees
with the shipped scripts, the shipped scripts win.

## 1. Goal

Give the operator a way to deploy, inspect, roll back, and delete Pocket Pages sites entirely from the
phone-friendly admin panel — no shell, no SSH — using the same vanilla-JS, no-framework, f-string `.box`
card idiom every other panel page already uses (`admin/app.py`'s `render()`, ~line 1503).

## 2. Non-goals (M2)

- An in-panel code editor or file browser for a site's contents (CLI-only, matches the "disable/delete
  stays CLI-only" precedent already applied to the app catalog).
- A build-log replay UI beyond the live SSE tail (§10) — no persisted, browsable build-log archive.
- Any WebSocket transport — SSE only, matching every other live-update surface in the panel.
- Multi-tenant per-site ACLs — single-operator model, unchanged from M1.
- Trusting anything client-side: JS-side name/size/extension checks in §7 are UX only, never a substitute
  for the server-side checks in §8.

## 3. Architecture decisions

### AD-1 — Termux-native filesystem access to `SITES_ROOT` (new pattern for `admin/app.py`)

`admin/app.py` currently never reads inside the proot userland rootfs — every existing route either shells
out (`run_script`/`run_script_detached`) or reads Termux-native paths (`DATA_DIR`, `POCKET_STATE_DIR`,
`POCKET_LOG_DIR`). Per SPEC-SITES-PIPELINE AD-2, `SITES_ROOT` lives at
`${PD_BASE}/debian/var/www/sites` where `PD_BASE="${PREFIX}/var/lib/proot-distro/installed-rootfs"` — the
exact host-side pattern already used by `ops/backup-all.sh:33` and `ops/restore.sh:43`. Add the same
constant to `admin/app.py`:

```python
PD_BASE    = os.path.join(_env("PREFIX", "/data/data/com.termux/files/usr"),
                           "var/lib/proot-distro/installed-rootfs")
SITES_ROOT = os.path.join(PD_BASE, "debian/var/www/sites")
SITES_STAGING  = os.path.join(SITES_ROOT, ".staging")
SITES_REGISTRY = os.path.join(SITES_ROOT, ".registry.json")
```

Reads (registry, per-site `meta.json`) and the upload staging write (§8) use this path directly — plain
file I/O, no proot round-trip, matching AD-2's "Termux-native code does plain file I/O on the host path"
rule. Only the (already-decided-in-M1) `site-deploy.sh`/`site-rollback.sh`/`site-delete.sh` scripts, run
detached, ever execute *inside* the userland.

### AD-2 — Registry reads are direct file I/O, not a `site-list.sh --json` subprocess

`GET /sites` needs to render on every page load; shelling out per request (like `run_script` does for
on-demand actions) would add a subprocess + proot-adjacent latency to a page that should feel instant.
Read `.registry.json` directly with `json.load()` — it's the same derived-state file `site-list.sh
--rebuild` can regenerate (SPEC-SITES-PIPELINE §5), so a stale/corrupt registry is self-healing, not a
panel bug. A **"rebuild registry"** button (`POST /sites/rebuild-registry`, `kind: mutate` in `SCRIPTS_OK`,
invoking `site-list.sh --rebuild`) is the escape hatch if the panel and the tree ever disagree.

### AD-3 — Upload is ONE `POST`, raw-streamed body; metadata rides in the query string + headers, never multipart

The task requires `request.stream` → disk, "never `request.files`". The reason that matters: Werkzeug's
default multipart parser (triggered the moment code touches `request.form`/`request.files` on a
`multipart/form-data` body) buffers each part through its own `stream_factory` — for a large file part that
means Werkzeug spills it to **its own** temp file *before* our view function gets a chance to enforce a
byte-for-byte cap or choose the destination path. That defeats both "hard read cap" and "server-allocated
staged path". Any request whose `Content-Type` is NOT `multipart/form-data` or
`application/x-www-form-urlencoded` leaves `request.stream` untouched and raw — so the design keeps the zip
upload OUT of form encoding entirely:

- Site **name** → query string (`?name=<name>`; not sensitive, fine to appear in a log line).
- **CSRF token** → request header `X-CSRF-Token` (a form field is impossible on a non-form body).
- **Admin password** (re-auth) → request header `X-Admin-Password` (kept out of the query string
  deliberately — Caddy's JSON access log records the full request URI, not headers, so a header keeps the
  password out of `landing`/vhost-style access logs the way a query param would not).
- **Body** = the raw zip bytes, `Content-Type: application/octet-stream` (JS sets this explicitly — see
  §7 — rather than trusting whatever MIME type the browser guesses for a `.zip` `File` object).

This is a deliberate single-round-trip design (no separate "init" call to mint an upload token): CSRF +
password + the stream all land in the one `POST /sites/upload`.

### AD-4 — `run_script_detached_argv`: a generalized detached-launch helper, kept OUT of `SCRIPTS_OK`

The task frames dispatch as "spawn the deploy DETACHED via a new `SCRIPTS_OK` entry invoking
`scripts/sites/site-deploy.sh <name> <staged> --job <id>`." Worth being precise about why that can't be a
literal `SCRIPTS_OK` entry: every one of the ~50 existing `SCRIPTS_OK` entries has a **fixed** `argv` list —
that's the whole point of the comment above the dict ("no user input ever reaches a shell — `run_script`
joins fixed argv"). Stretching `SCRIPTS_OK`'s schema to carry a *template* with placeholders would touch
`run_script`/`run_script_detached`'s shared code path used by every other action in the file, for the
benefit of exactly one caller. Instead:

```python
# Hardcoded — NEVER taken from request data. The only two Sites base scripts the
# panel is allowed to launch with a dynamic tail.
SITES_DEPLOY_SCRIPT   = "sites/site-deploy.sh"
SITES_ROLLBACK_SCRIPT = "sites/site-rollback.sh"

def run_script_detached_argv(base_script, extra_argv, logname):
    """Like run_script_detached, but appends a caller-supplied argv tail instead of
    a fixed SCRIPTS_OK entry. Every element of extra_argv MUST already be
    server-validated/allocated by the CALLER before this runs (name regex +
    reserved-list checked; staged path is ours; job id is ours) — this helper does
    not interpret its arguments, so it enforces nothing itself. base_script is
    always one of the two module-level constants above, never `request.*`."""
    cmd = ["bash", os.path.join(SCRIPTS, base_script)] + list(extra_argv)
    sink = os.path.join(LOGS, "adminweb-async.log")
    try:
        os.makedirs(LOGS, exist_ok=True)
        with open(sink, "ab", buffering=0) as lf:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=lf, stderr=lf,
                              start_new_session=True, close_fds=True)
        return True, logname
    except Exception:
        return False, logname
```

This keeps the existing invariant ("`SCRIPTS_OK`'s argv is fixed; nothing from a request reaches it")
literally true for the 50 existing actions, and confines the new "validate, then append" responsibility to
exactly the two call sites that need it (§8, §11).

### AD-5 — Rollback is CSRF-only, not danger-tier

SPEC-SITES-PIPELINE AD-4 makes rollback a pure pointer swap ("nothing is rebuilt, nothing is copied") —
cheap, instant, and itself trivially reversible (roll back the rollback). That puts it in the same
risk class as `panic-soft`/`restart-stack` (`reversible: True` in `DANGER_META`), not `rotate-reg-token` or
`delete-backup`. `POST /sites/<name>/rollback` uses the standard single `_csrf` form-field check
(`csrf_ok()`), like every "mutate"/"restart" `SCRIPTS_OK` action — no typed-phrase/password flow.

### AD-6 — Delete is danger-tier but PARAMETERIZED: mirror `/backups/delete`, not the generic `/confirm/<action_key>`

The generic `/confirm/<action_key>` route (`admin/app.py:2210`) only ever dispatches a **fixed, zero-arg**
`SCRIPTS_OK` script — there's no way to thread a per-request site `<name>` through it without the same
argv-template problem AD-4 avoided. The codebase already has the right precedent for a *parameterized*
danger action: `/backups/delete` (`admin/app.py:2351`) takes `bucket`/`file` as strictly-regex-validated
query/form values, reuses a `DANGER_META` entry for copy, and runs its own bespoke two-stage
GET(review)/GET(?stage=2, typed-confirm form)/POST(dispatch) flow instead of going through
`confirm_action()`. Site delete follows the same shape:

```python
DANGER_META["site-delete"] = {
    "title": "Delete site",
    "phrase": "delete site",
    "impact": [
        "Permanently removes ALL releases for this site — not just the live one.",
        f"The site's <name>.{DOMAIN} URL starts 404ing immediately.",
        "If this is the only copy of the source outside your own backup, it cannot be recovered.",
    ],
    "reversible": False,
}
```

`GET/POST /sites/<name>/delete` mirrors `backups_delete()`'s structure exactly (stage 1 impact review →
stage 2 phrase + `yes` + password → dispatch), with `<name>` validated against `SITE_SUB_RE` (§8) AND
required to exist in the registry before stage 1 even renders (404 otherwise — no probing for undeployed
names via this route). Dispatch runs `site-delete.sh <name> --yes` **synchronously** via a small
`run_script`-style call (delete is fast: unlink a dir tree + rewrite the registry — no build, no reason to
detach), reusing the `redact_secrets()` + `log_audit()` pattern from every other danger action.

### AD-7 — Deploy-log SSE gets its OWN session cap, is self-terminating, and duration-capped

`_SSE_MAX_PER_SESSION = 1` today caps only the dashboard's `/events` stream. gunicorn runs **1 worker × 4
gthreads** (`scripts/steps/70-install-admin.sh:178`) — every SSE connection permanently occupies one
gthread for as long as the stream is open. If deploy-log SSE shared the dashboard's `_SSE_SESSIONS` dict,
opening a deploy view while the dashboard tab is also open would immediately hit the existing cap and get
rejected. Give it a **separate** dict + cap (§10):

```python
_SITE_SSE_SESSIONS = {}
_SITE_SSE_SESSIONS_LOCK = threading.Lock()
_SITE_SSE_MAX_PER_SESSION = 1
```

Worst case per operator session: 1 dashboard stream + 1 deploy-log stream = 2 of 4 gthreads held, leaving 2
free for ordinary page loads. Unlike the dashboard stream (open until the tab closes), the deploy-log
stream is **self-terminating**: it closes the instant the job's state file flips to `done`/`failed`, and
carries a hard wall-clock ceiling (`SITES_BUILD_TIMEOUT` + margin) as a belt-and-suspenders exit in case a
job-state write is ever lost. A stream this short-lived is a much smaller exhaustion risk than the
open-ended dashboard one.

### AD-8 — Site health is NOT baked into the static `HEALTH_HTTP_PROBES` list; it's a lazy, capped, on-demand probe

`_build_http_probes()` (`admin/app.py:806`) runs **once at import time**, building `HEALTH_HTTP_PROBES` from
the `ENABLE_*` flags that are fixed for the life of the gunicorn worker. Sites are added/removed/redeployed
**without a panel restart** — baking them into that static list is simply the wrong lifecycle for this data.
Reasoned alternative (§14): a dedicated `GET /sites/health.json`, computed fresh (short-TTL cached) from the
registry each call, reusing the existing `_probe_http()` helper unmodified, capped in count and per-probe
timeout so a page with many sites — some possibly down — can never tie up a gthread for long:

```python
_SITE_HEALTH_TTL = 10.0
_SITE_HEALTH_MAX = 30        # mirrors the backups page's `files[:30]` cap
_SITE_HEALTH_TIMEOUT = 2     # vs the 5s default for fixed infra probes
```

### AD-9 — `SITES_SPA_MODE` is a global, install/toggle-time vhost change — never per-deploy

Per SPEC-SITES-PIPELINE OQ-4, `SITES_SPA_MODE` is a single global env var, resolved at panel-M2 time. It
changes the **ONE** wildcard vhost (`scripts/sites/sites.caddy.tmpl`), so it must go through the same
render+`caddy validate` path as install (§15) — **never** through a per-deploy code path, or it would
violate AD-1 of SPEC-SITES-PIPELINE ("deploys never touch Caddy again"). Add a **"reapply sites config"**
button on `/sites` (`POST /sites/apply-vhost`, a new `SCRIPTS_OK` entry re-running `apps/sites.sh`, `kind:
async`) mirroring the existing `apply-proxy-routes` precedent (`admin/app.py:183`) — so toggling
`SITES_SPA_MODE` in `.env` doesn't require a shell session to pick up.

### AD-10 — gunicorn `--timeout 60` is too short for a 200 MB synchronous upload; document the companion change

`scripts/steps/70-install-admin.sh:179` currently launches gunicorn with `--timeout 60 --graceful-timeout
30`. `POST /sites/upload` streams the request body synchronously inside a single gthread-handled request —
with `SITES_MAX_UPLOAD_MB=200` (default) and a conservative sustained-throughput assumption over the
Cloudflare Tunnel (~2 MB/s), a legitimate max-size upload can take on the order of 100s, comfortably past
the current 60s worker-silence timeout. **This spec does not edit `70-install-admin.sh`** (out of scope for
these two files), but flags the required companion change for whoever implements M2:

```diff
- --timeout 60 --graceful-timeout 30 \
+ --timeout 180 --graceful-timeout 30 \
```

`--graceful-timeout` (used only on a deliberate restart/SIGTERM) does not need to change. §18 OQ-3 revisits
the exact number if real-world tunnel throughput differs.

## 4. Nav integration

`render()`'s nav-item list (`admin/app.py:1512`) gets one new conditional entry, placed after the existing
`app-catalog` conditional and before the dynamic `problems` tab (grouping it with the other
optional-module sections rather than the "meta" tabs at the end):

```python
if ENABLE.get("sites"):
    items.append(("/sites", "sites"))
```

## 5. Routes (file-level)

| Route | Method | Auth | CSRF | Notes |
|---|---|---|---|---|
| `/sites` | GET | `login_required` | — (read-only) | site cards (§6) |
| `/sites/upload` | POST | `login_required` | `X-CSRF-Token` header | + `X-Admin-Password` header; streamed body (§7–§8) |
| `/sites/health.json` | GET | `login_required` | — | lazy, TTL-cached probe JSON (AD-8) |
| `/sites/deploy-log/<job_id>` | GET | `login_required` | — | SSE (§10) |
| `/sites/job/<job_id>` | GET | `login_required` | — | one-shot JSON poll fallback |
| `/sites/<name>/rollback` | POST | `login_required` | form `_csrf` | release id in form (§11) |
| `/sites/<name>/delete` | GET+POST | `login_required` | form `_csrf` (POST) | 2-stage danger confirm (§12) |
| `/sites/<name>/qr.svg` | GET | `login_required` | — | on-demand QR (§13) |
| `/sites/rebuild-registry` | POST | `login_required` | form `_csrf` | `SCRIPTS_OK` mutate → `site-list.sh --rebuild` |
| `/sites/apply-vhost` | POST | `login_required` | form `_csrf` | `SCRIPTS_OK` async → reruns `apps/sites.sh` (picks up `SITES_SPA_MODE`) |

Every route (including `GET /sites` itself) starts with `if not ENABLE.get("sites"): abort(404)` — the same
guard `/dav` uses when `radicale` is off.

## 6. Sites page (`GET /sites`) — cards, per-card actions, history

Read `.registry.json` (AD-2). For each site, the registry already carries everything the card needs
directly (SPEC-SITES-PIPELINE §5 schema) — `active_release`, `len(releases)`, `bytes`, `updated`, `url` — so
the page render does zero extra computation beyond formatting:

```
┌─────────────────────────────────────────────┐
│ 🌐 blog                          [● checking]│
│ https://blog.example.com                     │
│ release 20260717T1200Z-a1b2 · 3 releases     │
│ 4.2 MB · updated 2h ago                      │
│ [Rollback ▾] [QR] [History] [Delete]         │
└─────────────────────────────────────────────┘
```

- Card container reuses `.cardgrid` + `.box` (`admin/app.py:1387`,`:1378`) — no new grid CSS needed.
- The health pill (`[● checking]` above) starts in a neutral "checking…" state and is filled in by one JS
  `fetch('/sites/health.json')` after page load (AD-8) — it does **not** block the initial render.
- **Rollback**: a `<select>` of `releases` (newest first) inside a small inline `<form method=post
  action="/sites/<name>/rollback">` with the usual hidden `_csrf` field (§11).
- **QR**: a `<details>` disclosure containing `<img src="/sites/<name>/qr.svg" loading=lazy>` (§13) — no JS
  needed; evergreen browsers defer content (and its image fetches) inside a closed `<details>`, so the QR is
  only ever generated/fetched when the operator actually opens it.
- **History**: release ids are self-describing (`<UTC-ts>-<4hex>`, SPEC-SITES-PIPELINE §6) — the "created"
  column in the history table is parsed straight out of the id string; no extra registry field needed.
  Rendered as a plain `<table>` inside the same `<details>` as the release picker, newest first, with the
  active release visually marked (reuse the existing `tr.health-ok`-style `::before` dot idiom,
  `admin/app.py:1485`).
- **Delete**: a plain `<a href="/sites/<name>/delete" class="btn danger small">delete…</a>` — enters the
  two-stage flow in §12.

## 7. Upload flow — drag/drop + XHR (exact vanilla JS)

```html
<div class=box>
<h2><span class=ico>🚀</span> deploy a new site</h2>
<p class=small>Drop a .zip with <code>index.html</code> at its root (or use the CLI with
<code>--build hugo|node</code> for a source deploy). Re-enter your admin password to confirm —
the same re-auth the app catalog uses.</p>
<input id=site-name type=text placeholder="site name (a-z0-9-)"
       pattern="[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" required style="max-width:16rem">
<input id=site-pw type=password placeholder="admin password" autocomplete=current-password
       required style="max-width:16rem">
<div id=dropzone class=dropzone tabindex=0 data-csrf="{e(new_csrf())}">
  drop a .zip here, or click to choose
  <input id=site-file type=file accept=".zip" hidden>
</div>
<div id=upload-progress class=progress hidden><div id=upload-bar></div></div>
<pre id=upload-log class=small hidden></pre>
</div>
<script>
(function(){
  var zone = document.getElementById('dropzone'), fileInput = document.getElementById('site-file');
  var nameEl = document.getElementById('site-name'), pwEl = document.getElementById('site-pw');
  var bar = document.getElementById('upload-bar'), wrap = document.getElementById('upload-progress');
  var logEl = document.getElementById('upload-log');
  function pick(){ fileInput.click(); }
  zone.addEventListener('click', pick);
  zone.addEventListener('keydown', function(e){ if (e.key==='Enter'||e.key===' ') pick(); });
  ['dragenter','dragover'].forEach(function(ev){
    zone.addEventListener(ev, function(e){ e.preventDefault(); zone.classList.add('drag'); });
  });
  ['dragleave','drop'].forEach(function(ev){
    zone.addEventListener(ev, function(e){ e.preventDefault(); zone.classList.remove('drag'); });
  });
  zone.addEventListener('drop', function(e){
    var f = e.dataTransfer.files && e.dataTransfer.files[0];
    if (f) upload(f);
  });
  fileInput.addEventListener('change', function(){ if (fileInput.files[0]) upload(fileInput.files[0]); });

  function upload(file){
    var name = nameEl.value.trim(), pw = pwEl.value;
    if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(name)) { alert('enter a valid site name first'); return; }
    if (!pw) { alert('enter your admin password first'); return; }
    if (!/\.zip$/i.test(file.name)) { alert('only .zip is accepted'); return; }
    // Client-side hints only — the server enforces the real cap independently (§8/§9).
    wrap.hidden = false; bar.style.width = '0%'; logEl.hidden = true;
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/sites/upload?name=' + encodeURIComponent(name));
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.setRequestHeader('X-CSRF-Token', zone.dataset.csrf);
    xhr.setRequestHeader('X-Admin-Password', pw);
    xhr.upload.onprogress = function(e){
      if (e.lengthComputable) bar.style.width = Math.round(100 * e.loaded / e.total) + '%';
    };
    xhr.onload = function(){
      pwEl.value = '';  // never keep the password in the DOM after the request fires
      var res = {}; try { res = JSON.parse(xhr.responseText); } catch(_) {}
      if (xhr.status === 200 && res.job) { bar.style.width = '100%'; openDeployLog(res.job); }
      else { logEl.hidden = false; logEl.textContent = 'upload failed: ' + (res.error || xhr.status); }
    };
    xhr.onerror = function(){ pwEl.value = ''; logEl.hidden = false; logEl.textContent = 'upload failed: network error'; };
    xhr.send(file);
  }

  function openDeployLog(job){
    logEl.hidden = false; logEl.textContent = 'deploying…\n';
    if (!window.EventSource) { pollJob(job); return; }
    var es = new EventSource('/sites/deploy-log/' + job);
    es.onmessage = function(e){
      try {
        var d = JSON.parse(e.data);
        if (d.line) logEl.textContent += d.line + '\n';
        if (d.state === 'done')   { logEl.textContent += '\n✔ deployed\n'; es.close(); setTimeout(function(){ location.reload(); }, 1200); }
        if (d.state === 'failed') { logEl.textContent += '\n✘ failed: ' + (d.error||'') + '\n'; es.close(); }
      } catch(_) {}
    };
    es.addEventListener('toomany', function(){ es.close(); pollJob(job); });
  }
  function pollJob(job){
    var t = setInterval(function(){
      fetch('/sites/job/' + job, {credentials:'include'}).then(function(r){ return r.json(); }).then(function(d){
        if (d.state === 'done' || d.state === 'failed') {
          clearInterval(t);
          logEl.textContent += (d.state==='done' ? '\n✔ deployed\n' : '\n✘ failed: '+(d.error||'')+'\n');
          if (d.state === 'done') setTimeout(function(){ location.reload(); }, 1200);
        }
      }).catch(function(){});
    }, 2000);
  }
})();
</script>
```

New CSS (added to the `CSS` string, ~`admin/app.py:1271`, using existing tokens only — no new colors):

```css
.dropzone{border:2px dashed var(--border);border-radius:12px;padding:1.4rem;text-align:center;
  cursor:pointer;color:var(--muted);transition:border-color .15s,background .15s}
.dropzone.drag{border-color:var(--accent);background:var(--btn-bg)}
.progress{height:.5rem;border-radius:999px;background:var(--btn-bg);overflow:hidden;margin-top:.6rem}
#upload-bar{height:100%;background:var(--accent);width:0;transition:width .2s}
```

## 8. `POST /sites/upload` — server-side contract

```python
SITE_SUB_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')  # same pattern as SPEC-SITES-PIPELINE §7
# Duplication contract (mirrors SPEC-LANDING-SYNC's CSS-token contract): this list
# MUST equal scripts/sites/reserved-subs.sh's RESERVED_SUBS (the already-unioned
# list — that file exports no CORE_SUBS; the union was folded in at M1) — if you
# change one, change both. tests/ asserts parity (§17).
SITE_RESERVED = frozenset(
    "chat admin files music books audiobooks read dav wiki vault links share rss notes "
    "tasks search tools status stickers webmail ai mcp git dns "
    "www mail mta smtp imap pop autoconfig autodiscover matrix sites api cdn ns1 ns2 preview".split()
)
# Same shape as the pipeline's RELEASE_ID_RE (lib-sites.sh:49): {4,6} tolerates
# both HHMM and the HHMMSS form new_job_id() actually mints — the panel MUST
# accept pipeline-minted 6-digit ids (rollback/delete/CLI jobs all use them).
_JOB_RE = re.compile(r'^[0-9]{8}T[0-9]{4,6}Z-[0-9a-f]{4}$')

def csrf_ok_header():
    tok = request.headers.get("X-CSRF-Token", "")
    return bool(tok) and hmac.compare_digest(tok, session.get("csrf", ""))

def json_response(obj, status):
    r = make_response(json.dumps(obj), status)
    r.headers["Content-Type"] = "application/json"
    return r

@app.route("/sites/upload", methods=["POST"])
@login_required
def sites_upload():
    if not ENABLE.get("sites"):
        abort(404)
    if not csrf_ok_header():
        return json_response({"ok": False, "error": "bad csrf"}, 403)
    pw = request.headers.get("X-Admin-Password", "")
    if not pw or not verify_password(pw):
        log_audit("sites-upload", ok=False, reason="bad-password")
        return json_response({"ok": False, "error": "bad password"}, 401)

    name = (request.args.get("name") or "").strip()
    if not SITE_SUB_RE.fullmatch(name) or name in SITE_RESERVED:
        return json_response({"ok": False, "error": "invalid or reserved site name"}, 400)
    if _route_collision(name):   # /etc/caddy/apps/byo-<name>.caddy exists — the filename
                                 # proxy-routes.sh:206 actually writes; ALSO check
                                 # route-<name>.caddy as a belt (mirror lib-sites.sh §7)
        return json_response({"ok": False, "error": "name already used by a BYO proxy route"}, 400)

    length = request.content_length
    if length is None:
        return json_response({"ok": False, "error": "Content-Length required"}, 411)
    cap = SITES_MAX_UPLOAD_MB * 1024 * 1024
    if length > cap:
        return json_response({"ok": False, "error": f"upload exceeds {SITES_MAX_UPLOAD_MB} MB"}, 413)

    # HHMMSS — identical to the pipeline's new_job_id() (lib-sites.sh:141); the
    # panel must never mint an id shape the pipeline itself wouldn't produce.
    job = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(2)
    staged = os.path.join(SITES_STAGING, f"upload-{job}.zip")
    written = 0
    try:
        os.makedirs(SITES_STAGING, exist_ok=True)
        with open(staged, "wb") as f:
            stream = request.stream
            while True:
                chunk = stream.read(1 << 20)          # 1 MiB reads
                if not chunk:
                    break
                written += len(chunk)
                if written > cap:                      # belt-over-suspenders vs a lying Content-Length
                    raise ValueError("cap exceeded mid-stream")
                f.write(chunk)
        if written != length:
            raise ValueError("truncated upload")
    except Exception as ex:
        try: os.unlink(staged)
        except OSError: pass
        log_audit("sites-upload", name=name, ok=False, reason=str(ex))
        return json_response({"ok": False, "error": "upload incomplete or oversized"}, 400)

    ok2, _logname = run_script_detached_argv(
        SITES_DEPLOY_SCRIPT, [name, staged, "--job", job], f"site-deploy-{job}.log")
    log_audit("sites-upload", name=name, job=job, bytes=written, started=ok2)
    if not ok2:
        return json_response({"ok": False, "error": "could not start the deploy"}, 500)
    return json_response({"ok": True, "job": job}, 200)
```

## 9. `app.config['MAX_CONTENT_LENGTH']`

Add near the existing `app.config.update(...)` block (`admin/app.py:319`):

```python
# DoS bugfix independent of Sites: no route had ANY body-size ceiling before this
# (Werkzeug buffers form-encoded bodies into memory before a view function ever
# runs). Sized off SITES_MAX_UPLOAD_MB (the largest legitimate body any route
# expects) with headroom; the upload handler's own `length > cap` check in §8 is
# the PRECISE enforcement point — this is the blanket backstop.
app.config["MAX_CONTENT_LENGTH"] = (SITES_MAX_UPLOAD_MB + 16) * 1024 * 1024
```

Every existing POST endpoint gains this ceiling for free: `/login` (password field), `/catalog/install`
(password field), every `/confirm/<action_key>` POST (phrase/yes/password), `/backups/delete`, `/theme`,
`/action`, `/users` (if `ENABLE_USER_ADMIN`). Before this change, an **unauthenticated** POST to `/login`
with a multi-gigabyte body forced Werkzeug to buffer the whole thing into memory before credential checking
even ran — a pre-auth memory-exhaustion DoS on a RAM-constrained phone. This closes that for the whole app,
not just the new upload route.

## 10. Deploy-log SSE (`GET /sites/deploy-log/<job_id>`)

Reuses the `/events` generator shape (`admin/app.py:4371`) — same `make_response(stream(), 200)` +
`text/event-stream` headers — but tails a per-job log file and polls the job-state JSON instead of
`gather_stats_cached()`, and terminates itself instead of looping forever:

```python
_SITE_SSE_MAX_DURATION_S = int(_env("SITES_BUILD_TIMEOUT", "900")) + 120  # hard ceiling, belt-over-suspenders

@app.route("/sites/deploy-log/<job_id>")
@login_required
def sites_deploy_log(job_id):
    if not ENABLE.get("sites"): abort(404)
    if not _JOB_RE.fullmatch(job_id): abort(400)
    sid = request.cookies.get("session", "") or (request.remote_addr or "?")

    def stream():
        with _SITE_SSE_SESSIONS_LOCK:
            if _SITE_SSE_SESSIONS.get(sid, 0) >= _SITE_SSE_MAX_PER_SESSION:
                yield "event: toomany\ndata: {}\n\n"; return
            _SITE_SSE_SESSIONS[sid] = _SITE_SSE_SESSIONS.get(sid, 0) + 1
        try:
            log_path   = os.path.join(LOGS, f"site-deploy-{job_id}.log")
            state_path = os.path.join(STATE, f"site-job-{job_id}.json")
            pos, t0 = 0, time.time()
            while True:
                if time.time() - t0 > _SITE_SSE_MAX_DURATION_S:
                    yield 'data: {"state":"failed","error":"stream timeout"}\n\n'; return
                new_text = None
                try:
                    with open(log_path) as f:
                        f.seek(pos); new_text = f.read(); pos = f.tell()
                except OSError:
                    pass
                state, error = "running", None
                try:
                    with open(state_path) as f:
                        j = json.load(f)
                    state, error = j.get("state", "running"), j.get("error")
                except Exception:
                    pass
                yield "data: " + json.dumps({
                    "line": new_text.rstrip("\n") if new_text else None,
                    "state": state, "error": error,
                }) + "\n\n"
                if state in ("done", "failed"):
                    return
                time.sleep(1)
        except GeneratorExit:
            return
        finally:
            with _SITE_SSE_SESSIONS_LOCK:
                n = _SITE_SSE_SESSIONS.get(sid, 1) - 1
                if n <= 0: _SITE_SSE_SESSIONS.pop(sid, None)
                else: _SITE_SSE_SESSIONS[sid] = n
    r = make_response(stream(), 200)
    r.headers["Content-Type"] = "text/event-stream"
    r.headers["Cache-Control"] = "no-cache"
    r.headers["X-Accel-Buffering"] = "no"
    return r


@app.route("/sites/job/<job_id>")
@login_required
def sites_job_status(job_id):
    if not _JOB_RE.fullmatch(job_id): abort(400)
    try:
        with open(os.path.join(STATE, f"site-job-{job_id}.json")) as f:
            j = json.load(f)
    except Exception:
        j = {"state": "running"}
    return json_response(j, 200)
```

`log_path`/`state_path` reuse `LOGS`/`STATE` (already-defined `POCKET_LOG_DIR`/`POCKET_STATE_DIR`
constants) directly — matching SPEC-SITES-PIPELINE AD-6's `${POCKET_LOG_DIR}/site-deploy-<JOB_ID>.log` /
`${POCKET_STATE_DIR}/site-job-<JOB_ID>.json` paths verbatim.

## 11. Rollback (`POST /sites/<name>/rollback`)

```python
@app.route("/sites/<name>/rollback", methods=["POST"])
@login_required
def sites_rollback(name):
    if not ENABLE.get("sites"): abort(404)
    if not csrf_ok(): abort(403)
    if not SITE_SUB_RE.fullmatch(name): abort(400)
    release = (request.form.get("release") or "").strip()
    reg = _read_sites_registry()
    site = reg.get("sites", {}).get(name)
    if not site:
        flash_msg(f"unknown site: {name}", "err"); return redirect(url_for("sites_page"))
    if release and release not in site.get("releases", []):
        flash_msg("unknown release id", "err"); return redirect(url_for("sites_page"))
    argv = [name] + ([release] if release else [])
    rc, out = run_script_argv(SITES_ROLLBACK_SCRIPT, argv, timeout=60)  # fast, synchronous (AD-5)
    log_audit("sites-rollback", name=name, release=release or "previous", rc=rc)
    flash_msg(f"rolled back {name}" if rc == 0 else f"rollback failed: {redact_secrets(out)[:300]}",
              "ok" if rc == 0 else "err")
    return redirect(url_for("sites_page"))
```

`run_script_argv` is a two-line generalization of the existing `run_script()` (`admin/app.py:524`) that
takes an explicit script path instead of a `SCRIPTS_OK` key — same synchronous `subprocess.run` shape, same
`(rc, out)` return, used ONLY here and by `/sites/<name>/delete` (§12), both with server-validated argv.

## 12. Delete (`/sites/<name>/delete`, danger typed-confirm)

Structure is a line-for-line mirror of `backups_delete()` (`admin/app.py:2351`): `name` validated + required
to already exist in the registry before stage 1 renders; stage 1 = impact review (from `DANGER_META["site-
delete"]`, AD-6); stage 2 = phrase + `yes` + password; POST = dispatch `site-delete.sh <name> --yes`
synchronously via `run_script_argv`, then `log_audit` + redirect to `/sites` with a flash message. No new UI
patterns — copy `backups_delete()`'s three form blocks verbatim, substituting the bucket/file params for a
single `name` param and the `DANGER_META` key.

## 13. QR share (`GET /sites/<name>/qr.svg`)

Mirrors `/dav`'s segno usage (`admin/app.py:2824`) exactly — lazy `import segno`, graceful degrade, QR
encodes ONLY the public URL (never a secret):

```python
@app.route("/sites/<name>/qr.svg")
@login_required
def sites_qr(name):
    if not ENABLE.get("sites"): abort(404)
    if not SITE_SUB_RE.fullmatch(name): abort(400)
    url = f"https://{name}.{DOMAIN}"
    try:
        import segno
        svg = segno.make(url, error="m").svg_inline(scale=5, border=2)  # raw SVG, not a data-URI (img endpoint)
    except Exception:
        abort(404)  # the card's <details> just shows nothing; no broken-image UX beyond that
    r = make_response(svg, 200)
    r.headers["Content-Type"] = "image/svg+xml"
    r.headers["Cache-Control"] = "public, max-age=300"
    return r
```

Loaded via `<img src="/sites/<name>/qr.svg" loading=lazy>` inside a `<details>` (§6) — segno already ships
with the panel venv (`scripts/steps/70-install-admin.sh:76`, best-effort install), so no new dependency.

## 14. Health probing

```python
_SITE_HEALTH_CACHE = {"data": None, "ts": 0.0}

def _read_sites_registry():
    try:
        with open(SITES_REGISTRY) as f:
            return json.load(f)
    except Exception:
        return {"version": 1, "sites": {}}

def _site_probes():
    now = time.time()
    if _SITE_HEALTH_CACHE["data"] is not None and now - _SITE_HEALTH_CACHE["ts"] < _SITE_HEALTH_TTL:
        return _SITE_HEALTH_CACHE["data"]
    reg = _read_sites_registry()
    out = {}
    for name in sorted(reg.get("sites", {}))[:_SITE_HEALTH_MAX]:
        probe = {"name": name, "host": f"{name}.{DOMAIN}", "path": "/", "expect": 200, "scheme": "loopback"}
        out[name] = _probe_http(probe, timeout=_SITE_HEALTH_TIMEOUT)
    _SITE_HEALTH_CACHE.update(data=out, ts=now)
    return out

@app.route("/sites/health.json")
@login_required
def sites_health_json():
    if not ENABLE.get("sites"): abort(404)
    return json_response(_site_probes(), 200)
```

The Sites page's JS does one `fetch('/sites/health.json')` after load and patches each card's pill via
`document.querySelector` — the same DOM-patch idiom `_SSE_SCRIPT` uses (`admin/app.py:3142`'s `html()`/
`set()` helpers), just via a single fetch instead of a stream (10s cache freshness is plenty; sites don't
need per-second liveness like the dashboard's load/mem numbers).

## 15. `SITES_SPA_MODE` + the wildcard vhost

`scripts/sites/sites.caddy.tmpl` gains one new substitution token, `__SPA_TRY_FILES__`, defaulting to empty
and set by `scripts/apps/sites.sh` (not by the panel — see AD-9) to:

```caddyfile
	try_files {path} {path}/ /index.html
	file_server
```

...replacing the bare `file_server` line when `SITES_SPA_MODE=true`.

> **CORRECTION (2026-07-17, during implementation validation):** this spec originally drafted the SPA block
> as `route { try_files {path} /index.html; file_server }`. That form is a **security bug**: Caddy's
> directive sort order runs `route` BEFORE `respond`, so the wrapped `file_server` handles the request
> before the vhost's `respond @dot 403` dotfile guard ever runs — probed on caddy v2.11.4, where the
> route-wrapped form served an existing `/assets/.env` with a 200. The sibling form above is the correct
> one: `try_files` sorts before `respond`, so an EXISTING dotfile keeps its original path and still 403s
> (only nonexistent paths rewrite to the SPA shell), and `{path}/` keeps subdirectory index pages working
> (without it, `/docs` rewrites to the root `/index.html` instead of redirecting to `/docs/`).

(`try_files` requires a reasonably
current Caddy — verify against the installed `caddy version` before implementing; `scripts/steps/30-install-
caddy.sh` tracks the apt "stable" channel, unpinned, so this should already be satisfied in practice.) The
panel's `/sites/apply-vhost` button (AD-9) is the only in-panel way to pick up a `SITES_SPA_MODE` change —
it reruns `apps/sites.sh`, which re-renders + re-`caddy validate`s the ONE wildcard vhost, same as any other
install-time config change.

## 16. Threat model

| Threat | Mitigation |
|---|---|
| Upload DoS (huge/slow body exhausts memory or a gthread) | `Content-Length` required (411 otherwise) + hard 413; streamed to disk in 1 MiB chunks, never buffered in memory; global `MAX_CONTENT_LENGTH` backstop (§9); gunicorn `--timeout` raised to survive a legitimate max-size upload (AD-10) |
| Zip bomb / path traversal inside the artifact | Out of panel scope by design — enforced by M1's `safe_extract.py` (SPEC-SITES-PIPELINE §8) inside `site-deploy.sh`, which the panel always calls and never bypasses |
| Path/command injection via site name | `SITE_SUB_RE` + reserved-list check BEFORE the name touches argv or a filesystem path; same regex/list source as `scripts/sites/reserved-subs.sh` (duplication contract, §8) |
| Argv injection via the staged artifact path or job id | Both are 100% server-allocated — the client never supplies a path or job id to `/sites/upload`; `job_id` is regex-validated in every route that accepts it before touching the filesystem |
| CSRF on state-changing routes | Double-submit token everywhere — form field (`_csrf`) for normal forms, header (`X-CSRF-Token`) for the raw-body upload where a form field is impossible |
| Session fixation / stale session reuse | Existing `BOOT_NONCE` check in `login_required` — unchanged, applies to every Sites route automatically |
| Password re-auth bypass on upload | `X-Admin-Password` re-checked with `verify_password()` on every upload, mirroring `catalog_install`; never cached or reused |
| Password leakage into logs | Sent as a header, not a query string (Caddy's JSON access logs record the request line/URI, not headers); `redact_secrets()` still scrubs `adminweb-async.log` as a backstop |
| SSE thread exhaustion (4 gthreads total) | Dashboard and deploy-log SSE use SEPARATE session-cap dicts, each capped at 1/session (worst case 2 of 4 gthreads/operator); deploy-log SSE is also self-terminating + duration-capped (AD-7), unlike the open-ended dashboard stream |
| Reserved/BYO-route name squatting | `SITE_SUB_RE` + reserved list + the BYO-route collision check from SPEC-SITES-PIPELINE §7 |
| QR endpoint used as an SSRF/redirect gadget | Only ever encodes `https://<validated-name>.<DOMAIN>` — no user-supplied URL is ever embedded (mirrors `/dav`'s existing invariant) |
| Public directory listing leaking a not-meant-for-listing site | Cross-cutting with the landing page, not this panel — see SPEC-LANDING-SYNC §11 OQ-1 |

## 17. Test plan

**Unit-testable** (pytest, extending M1's `tests/`):
- `SITE_SUB_RE` + `SITE_RESERVED` parity: a test that parses `scripts/sites/reserved-subs.sh`'s reserved
  list and asserts the Python constant is exactly equal — fails loudly the moment the two drift (the
  duplication-contract enforcement mechanism, same idea as SPEC-LANDING-SYNC's CSS-token contract).
- Upload-cap logic pulled into a pure helper, `_check_upload_budget(content_length, cap_bytes) -> (bool,
  str|None)`, with no Flask/request dependency — tested directly (over cap, exactly at cap, zero, garbage).
- `csrf_ok_header()` against matching/mismatched/missing header.
- `_JOB_RE` / release-id regex tests (valid id; id with `/`, `..`, or shell metacharacters — all rejected).
- `run_script_detached_argv` / `run_script_argv` tested with a no-op fake `base_script`, asserting the
  final argv shape and that neither ever reads from `SCRIPTS_OK`.

**Needs E2E** (arm64 qemu, extends M1's harness):
- Good upload → 200 + job id → SSE (or `pollJob` fallback) reaches `done` → `curl -H "Host: <name>.<domain>"`
  returns 200 with the deployed content.
- Reserved/invalid name → 400, nothing staged, nothing spawned.
- Content-Length under-reports the real size → mid-stream 413, partial `.staging` file removed.
- Missing Content-Length → 411.
- Wrong password → 401 + `log_audit` entry, no job created.
- Missing/garbage `X-CSRF-Token` → 403.
- Rollback: valid release id flips content immediately with no non-200 during the swap (mirrors M1's own
  curl-loop assertion); unknown release id → 400/flash error, no dispatch.
- Delete: stage-1 GET alone changes nothing; full 3-stage POST (phrase + `yes` + password) → site 404s +
  registry entry gone.
- SSE session cap: a 2nd deploy-log tab for the same session gets the `toomany` event, and its JS fallback
  (`pollJob`) still reaches `done`.
- `/sites/health.json`: a site whose `current` symlink is intentionally broken reports `ok:false` within one
  `_SITE_HEALTH_TTL` window.

**Laptop smoke:**
- `python3 -c "import ast; ast.parse(open('admin/app.py').read())"` — the same check
  `70-install-admin.sh:85` already runs on every install; confirms the diff still parses.
- A local Flask test-client smoke: POST `/sites/upload` with no session cookie → redirected to `/login`
  (confirms `login_required` covers the new route); POST with a session but no `X-CSRF-Token` → 403.

## 18. Open questions (for operator/approval before implementation)

- **OQ-1**: Should `/sites/upload`'s password re-auth be skippable on a redeploy of an *already-existing*
  site (lower friction for iterative deploys), or always required (this draft's default, mirroring
  `catalog_install` exactly — the one endpoint that also accepts a raw file body)?
- **OQ-2**: Is the 30-site cap on `/sites/health.json` (AD-8) the right number, or should it become
  `SITES_HEALTH_MAX` (env-overridable, following the existing `SITES_*` naming convention)?
- **OQ-3**: AD-10's `--timeout 180` assumes ~2 MB/s sustained over the Cloudflare Tunnel for a 200 MB
  upload. If real-world throughput is worse, either the timeout needs to grow further, or `docs/SITES.md`
  needs an explicit callout that off-tunnel uploads (`ssh -L`, local Wi-Fi) are meaningfully faster.

**Resolutions (2026-07-17, at approval):** OQ-1 — always require password re-auth (the draft's default;
mirrors `catalog_install`). OQ-2 — keep the fixed 30 cap for M2; revisit only if a real deployment hits
it. OQ-3 — ship `--timeout 180` + add the docs/SITES.md callout that off-tunnel uploads are faster.
