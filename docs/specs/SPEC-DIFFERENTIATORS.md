# SPEC-DIFFERENTIATORS — Pocket Pages M4: git-push-to-deploy, share-sheet deploy, forms, analytics-lite

**Status: ACCEPTED FOR IMPLEMENTATION — 2026-07-19.** Implements plan §5 M4. Drafted, then
line-by-line review-validated the same day (corrections C-1..C-3 below). The operator's standing
directive ("continue and finish all work … till my intervention is required") authorizes implementation
with the conservative OQ defaults recorded at the end of §14; the operator retains veto on every OQ
default at the pre4 review, and the v1.1.0 FINAL tag remains explicitly operator-gated.

> **REVIEW CORRECTIONS (2026-07-19, pre-approval line-by-line validation).** Three findings from the
> review pass, folded in below as dated corrections rather than silent rewrites (the same convention as
> SPEC-SITES-PANEL §15's CORRECTION block). They supersede the contradicted sentences where they appear.
>
> **C-1 — §7's central claim is wrong: the Android Share Sheet target DOES exist.** §7.2 item 3 asserts
> the base Termux app's manifest "has no `ACTION_SEND` intent-filter". Re-verified against
> `termux-app@master`'s actual `app/src/main/AndroidManifest.xml`: activity
> `.app.api.file.FileShareReceiverActivity` registers `android.intent.action.SEND` with mime types
> `application/*` (which includes zips), `text/*`, `image/*`, `audio/*`, `video/*`, `message/*`,
> `multipart/*`. Its handler (`FileReceiverActivity.java`, read at source): a shared **file** is saved to
> `~/downloads` (with a user filename-confirm dialog) and `~/bin/termux-file-editor <absolute-path>` is
> executed; a shared **URL** executes `~/bin/termux-url-opener <url>`. **Corrected design:** the headline
> feature IS buildable as a share-sheet deploy with zero companion APK — ship a no-clobber
> `~/bin/termux-file-editor` hook (installed only if absent, or refusing with instructions if the operator
> already has one; the shipped script handles `*.zip` → prompt site name → `site-deploy.sh`, and falls
> through to `${EDITOR:-nano}` for every non-zip file so the hook's normal file-editing purpose is
> preserved). Honest caveats that stand: the share-sheet entry is labeled **"Termux"** (the receiving
> app), not "pocket-homeserver" — only a companion APK could change that; the hook is a single global
> file (hence the no-clobber discipline); on-device validation remains manual (§7.9). §7.3's
> Termux:Widget one-tap flow is KEPT as the secondary path (it is cheap and complements the share flow).
> **OQ-2 is superseded**: the ask is now "bless the share-hook design + widget companion (with the
> 'Termux' label caveat), or trim to one of the two paths."
>
> **C-2 — §8's "cannot self-attribute" claim is false; forms site-attribution needs a gate token.** AD-7's
> defense ("the route 404s if `X-Pocket-Site` is absent") does not survive its own threat model: (a) any
> on-device app with the INTERNET permission can POST directly to the panel's loopback bind **and set the
> header itself** — the exact loopback-is-not-a-trust-boundary reasoning §6.6 already quotes from
> `maddy.conf.tmpl:54-55`; (b) the admin vhost (`scripts/steps/70-install-admin.sh:208-211`) forwards
> client headers to the panel unmodified, so `admin.${DOMAIN}/__pocket-forms__/...` with a client-forged
> `X-Pocket-Site` reaches the login-free forms route from the internet when CF Access is not enforced.
> **Correction:** `apps/sites.sh` mints a `SITES_FORMS_GATE_TOKEN` (`openssl rand -hex 32`) at
> render/toggle time, substitutes it into the sites vhost's forms block (`header_up X-Pocket-Forms-Gate
> <token>` alongside the strip-then-set of `X-Pocket-Site`) and writes it 0600 to
> `${POCKET_STATE_DIR}/sites-forms.gate` for the panel to read; the forms route 404s unless the header
> matches (`hmac.compare_digest`). Belt: `70-install-admin.sh`'s vhost strips inbound `X-Pocket-Site` and
> `X-Pocket-Forms-Gate` before proxying. This makes Caddy's sites vhost the *provable* sole attributor,
> which is what AD-7 claimed but did not enforce. (Same "secret minted by the installer, 0600 file, never
> argv" convention as the existing secrets machinery.)
>
> **C-3 — §8's rate-limit/IP source is wrong behind the tunnel: `{client_ip}` is the local cloudflared
> hop.** With the default CF Tunnel ingress, Caddy's `{client_ip}` for visitor traffic is the tunnel
> daemon's local address, not the visitor — this repo's own `honeypot-watcher.py:469-507` documents and
> solves exactly this by preferring the `Cf-Connecting-IP` header with `client_ip`/`remote_ip` fallback.
> As specced, AD-7's `header_up X-Forwarded-For {client_ip}` would collapse every visitor into ONE
> rate-limit bucket (a spammer rate-limits all legitimate visitors of all sites) and make the stored
> `ip_truncated` meaningless. **Correction:** drop that `header_up` line (request headers, including
> `Cf-Connecting-IP`, already flow through `reverse_proxy` by default); the forms route derives the
> abuse-key/`ip_truncated` IP via the same preference chain as `parse_line()`: `Cf-Connecting-IP` →
> `X-Forwarded-For` (ProxyFix) → `remote_addr`. The unit tests (§8.7) must cover all three sources.
>
> **C-4 (2026-07-19, found by the arm64 E2E) — C-2's "strip-then-set" `header_up` sketch is broken on
> real Caddy: a same-header delete listed alongside a set in one `reverse_proxy` block runs AFTER the
> set and wipes Caddy's own value.** As corrected by C-2, the forms block carried `header_up
> -X-Pocket-Site` + `header_up X-Pocket-Site {labels.N}` (and the same pair for the gate header). Caddy
> does not apply header ops in written order within a block — the upstream received NEITHER header
> (proven with a header-dump upstream), so every legitimate form POST 404'd while the C-2 negatives
> passed vacuously. **Correction:** the forms block is SET-only — a `header_up` SET already replaces any
> client-supplied value wholesale (proven live: forged `X-Pocket-Site`/`X-Pocket-Forms-Gate` arrive
> upstream as Caddy's values, exactly one each), so C-2's security property holds with no delete at all.
> The admin vhost's belt (`70-install-admin.sh`) is delete-ONLY (no set for those headers in that
> block) and is unaffected — deletes do execute; they just cannot be paired with a set for the same
> header. The E2E now asserts the delete+set pattern is ABSENT from the rendered forms block.

Milestone: M4 of the Pocket Pages program (v1.1.0), the last milestone before final. Depends on
[SPEC-SITES-PIPELINE.md](SPEC-SITES-PIPELINE.md) (M1, APPROVED — job model, registry, name validation,
filesystem layout — shipped `v1.1.0-pre1`), [SPEC-SITES-PANEL.md](SPEC-SITES-PANEL.md) (M2, APPROVED —
admin-panel Sites UI, upload/CSRF/detached-launch conventions — shipped `v1.1.0-pre2`), and
[SPEC-MCP-COMPLETION.md](SPEC-MCP-COMPLETION.md) (M3, APPROVED — MCP `sites` tool group + operator parity —
shipped `v1.1.0-pre3`). This spec covers the four operator-approved differentiator features named in the
program plan: **git-push-to-deploy** (Forgejo webhooks), **share-sheet deploy** (Termux:API), a
**Netlify-Forms clone**, and **analytics-lite**. QR-code live URLs already shipped in M2
(`admin/app.py:3359-3386`, `sites_qr()`) and are not re-specified here. Preview URLs, content-addressed
uploads, and a serverless function runner are out of scope for v1.1.0 (SPEC-SITES-PIPELINE §2) and stay on
the v1.2 roadmap.

---

## 1. Prerequisite check — M1, M2, M3 are shipped and tagged

Verified against the working tree (HEAD `f399ca7`, tree clean) rather than assumed from the program plan:

```
f399ca7 release: v1.1.0-pre3 — Pocket Pages M3 (changelog roll)
b628aca mcp: Pocket Pages M3 — sites tools, operator parity, first MCP tests
2d50112 specs: approve SPEC-MCP-COMPLETION (M3) with OQ resolutions
811c22d release: v1.1.0-pre2 — Pocket Pages M2 (changelog roll)
253a031 sites: Pocket Pages M2 — admin-panel deploy UI, synced landing, SPA mode
a8b12a4 release: v1.1.0-pre1 — Pocket Pages M1 (changelog roll)
```

`CHANGELOG.md`'s topmost entry is `## [1.1.0-pre3] - 2026-07-19` (`CHANGELOG.md:8`), confirming M3's MCP
`sites` tool group, operator-parity tools, and widened `pocket_logs` allowlist are live. This spec designs
M4 **against that shipped surface** — every file-by-file change below cites the actual line ranges in the
working tree, not the M1–M3 spec sketches, per the standing rule those specs already established (shipped
code wins; deviations are called out, §16).

## 2. Goal

Ship four independently-flagged, off-by-default features that make Pocket Pages feel like a real Netlify
alternative, each reusing the M1 pipeline / M2 panel / M3 job model rather than inventing a parallel one:

1. **Git-push-to-deploy** — push to a repo on the bundled Forgejo → its plain webhook (not Forgejo Actions,
   no CI runner, no Docker) → the pushed commit is archived and handed to the *existing*
   `sites/site-deploy.sh` pipeline exactly as the panel's upload route already does.
2. **Share-sheet deploy** — a one-tap, on-phone path from "a zip/folder sitting somewhere on the device" to
   a deploy, built from *verified* Termux:API/Termux-ecosystem primitives (§8 explains why this is **not**
   literally "Share → pocket-homeserver" from Android's system Share Sheet, and what it is instead).
3. **Netlify-Forms clone** — static HTML forms on a deployed site get a working public POST endpoint;
   submissions land in SQLite and optionally relay by email through the already-bundled Maddy.
4. **Analytics-lite** — per-site traffic counts parsed from Caddy's JSON access log, computed on demand
   (no new daemon), rendered in the admin panel, with a documented, privacy-conscious IP-handling stance.

## 3. Non-goals (M4 / v1.1.0)

Carried forward from SPEC-SITES-PIPELINE §2 (v1.2 roadmap, unchanged by this spec): content-addressed
incremental uploads, preview-then-promote deploy URLs, per-site custom Caddy config, serverless functions,
multi-tenant/user-owned sites. Additionally, in scope for M4 specifically:

- **No Forgejo Actions / CI runners.** The brief is explicit: plain webhooks only. `[actions] ENABLED =
  false` is already asserted in the shipped `app.ini` (`scripts/apps/forgejo.sh:271-273`) — this spec does
  not touch that.
- **No external git-host webhooks (GitHub/GitLab/etc.).** Only the bundled Forgejo is a supported sender.
  Nothing here stops an operator from adapting the receiver for another host by hand, but it is not designed
  or tested against one.
- **No literal Android system Share Sheet integration.** §8 documents why this is not achievable with the
  tools this repo already depends on, without shipping a companion APK (explicitly out of scope — this is a
  bash+Python self-hosted stack, not an Android app project).
- **No per-site webhook branch configuration in M4.** One global default branch (`SITES_WEBHOOK_BRANCH`,
  default `main`) applies to every site's webhook; per-site override is an OQ (§14, OQ-3).
- **No spam-model beyond honeypot-field + rate-limit.** No CAPTCHA, no ML classifier, no third-party
  anti-spam API call (would add an outbound network dependency + a privacy question for a "no client-side
  JS" feature).
- **No historical analytics beyond what the rotated access log physically retains.** Analytics-lite reads
  the live Caddy JSON log; it does not ingest into a separate long-lived time-series store (§9's AD
  explains why, and names the retention caveat explicitly rather than promising a fixed window the data
  can't back).
- **No new supervised/long-running process anywhere in this spec.** Every one of the four features rides an
  *existing* process (the admin panel's gunicorn worker, or a script invoked synchronously/on-demand) — see
  AD-1.

## 4. Verified ground truth (cited, reused across every feature below)

**Sites pipeline (M1), `scripts/sites/`:**
- `PD_BASE`/`SITES_ROOT`/`STAGING`/`REGISTRY` path resolution and the "Termux-native host-side view of the
  userland rootfs" pattern: `scripts/sites/lib-sites.sh:25-38`.
- `SUB_RE`/`RELEASE_ID_RE`, `validate_site_name()` (regex + `RESERVED_SUBS` + BYO-route collision check),
  `validate_release_id()`: `scripts/sites/lib-sites.sh:40-49,94-132`. `RESERVED_SUBS` itself:
  `scripts/sites/reserved-subs.sh:39` (includes `git` — the bundled Forgejo's own label — and `sites`,
  `api`, `cdn`, `preview`; does **not** reserve anything resembling `__pocket-forms__`, which this spec picks
  precisely because it cannot collide, §10).
- `host_to_userland()` (strip the rootfs prefix to get the userland-relative path for anything executed *in*
  the userland via `proot-distro`): `scripts/sites/lib-sites.sh:58-65`.
- `new_job_id()`/`new_release_id()` (`<UTC-ts>-<4hex>`): `scripts/sites/lib-sites.sh:140-141`.
- Job model — `job_start`/`job_done`/`job_fail`/`job_log`, one JSON state file per job under
  `${POCKET_STATE_DIR}/site-job-<id>.json`, one log under `${POCKET_LOG_DIR}/site-deploy-<id>.log`:
  `scripts/sites/lib-sites.sh:338-438`.
- `registry_update_site()` (atomic `.registry.json` upsert, recomputes `releases[]`/`bytes` from disk, never
  trusts a passed-in releases list): `scripts/sites/lib-sites.sh:531-604`. `_site_meta_build()` (read a
  site's recorded `build` tier from `meta.json`, default `"none"`): `scripts/sites/lib-sites.sh:226-241`.
- `site-deploy.sh`'s staging-containment rule: a **non-interactive** caller (`[ ! -t 0 ]`) must pass an
  artifact path that realpath-resolves inside `${STAGING}`, or the script dies; an interactive tty caller is
  exempt (CLI convenience): `scripts/sites/site-deploy.sh:84-94`. Build-tier dispatch executes **in the
  userland** via `proot-distro login debian -- bash -lc "..."` for both Hugo (`site-deploy.sh:204-205`) and
  Node (`site-deploy.sh:267-268`) — this is the established "proot only for execution, plain file I/O for
  everything else" split (AD-2 of SPEC-SITES-PIPELINE) this spec's webhook feature reuses for `git archive`.
- `sites.caddy.tmpl` already anticipates this milestone: *"NOTE (M4/analytics-lite): a per-vhost `log`
  directive lands with the analytics feature; deliberately absent in M1."* (`scripts/sites/sites.caddy.tmpl:29-30`).
  The `@dot` dotfile-403 guard matches `/.* */.*` (`sites.caddy.tmpl:51-52`); the SPA-mode comment documents a
  real, previously-probed Caddy ordering hazard (`route{}` wrapping sorts before `respond`) that this spec's
  forms feature must not repeat (§10's AD explains why it doesn't apply here).
- `scripts/apps/sites.sh` renders the ONE wildcard vhost via `sed` substitution of `${DOMAIN}`/`${CADDY_PORT}`/
  `${CADDY_BIND}`/`__L__`/`__SPA_TRY_FILES__`, then `caddy validate` fail-closed, then does **not** restart
  Caddy itself (`scripts/apps/sites.sh:94-117`) — it is re-run idempotently (full overwrite) whenever the
  operator re-applies the sites config, which is exactly how a new `log`/forms-matcher block added to the
  template reaches a phone that installed the sites module before M4.

**Admin panel (M2), `admin/app.py`:**
- `ENABLE` dict (`admin/app.py:114-154`), `SCRIPTS_OK` allowlist (`:158-213`), `APP_CATALOG` (`:223-239`),
  `DANGER_META` (`:247-323`) — the three closed-world dicts every new panel capability must extend, never
  bypass.
- `run_script`/`run_script_detached` (fixed `SCRIPTS_OK` key, sync/detached): `admin/app.py:566-600`.
  `run_script_argv`/`run_script_detached_argv` (explicit script path + server-validated argv tail, for a
  per-request path/job id that a fixed `SCRIPTS_OK` entry can't carry): `admin/app.py:2776-2810`.
- `SITE_SUB_RE`/`SITE_RESERVED`/`_SITE_JOB_RE` and the three sites-script path constants:
  `admin/app.py:2739-2759`. `_read_sites_registry()` (direct `json.load()`, degrades to an empty registry on
  any error, never raises): `admin/app.py:2813-2823`. `_route_collision()` (BYO-proxy-route collision check
  mirroring `validate_site_name()`): `admin/app.py:2826-2837`.
- `sites_upload()` (`admin/app.py:3104-3161`) is the closest prior art for **both** new inbound-content
  routes this spec adds (webhook receiver, forms receiver): validate → cap-checked stream-to-disk (or, for
  forms, cap-checked read-to-memory) → mint a job id the same shape the pipeline itself would mint
  (`admin/app.py:3131`) → `run_script_detached_argv(...)` → return immediately with a job id the client polls.
- `app.config["MAX_CONTENT_LENGTH"]` is sized off `SITES_MAX_UPLOAD_MB` with headroom
  (`admin/app.py:358-366`) — the blanket backstop for every POST route, including the two new ones.
- `_cf_access_gate()` is an `@app.before_request` hook that is **inert unless the request carries a
  `Cf-Access-Jwt-Assertion` header** (`admin/app.py:1743-1767`, esp. the `"loopback-only path — allow"`
  comment at `:1753`) — a loopback-originated request (Forgejo calling the admin panel's own bind address
  directly) passes through untouched; this is why the webhook receiver needs no Cloudflare Access carve-out.
- `hmac.compare_digest` is already the constant-time-comparison idiom for both CSRF (`admin/app.py:2766-2767`)
  and password verification (`admin/app.py:440`); `admin/app.py:1708` uses it for the CF Access JWT check too.
- `gather_stats_cached()`/`_STATS_CACHE`/`_STATS_TTL` (module-level dict + lock + TTL, `admin/app.py:3914-3933`)
  and the sites-specific `_site_probes()`/`_SITE_HEALTH_CACHE`/`_SITE_HEALTH_TTL`
  (`admin/app.py:2931-2957`) are the established "compute-on-read with a short-TTL shared cache" pattern this
  spec's analytics feature reuses instead of a new daemon.
- `rate_limit_login()`/`record_fail()`/`_FAILS`/`_save_fails_unlocked()` (`admin/app.py:464-552`) is the
  established per-IP abuse-counter idiom (in-memory dict + disk-persisted, exponential backoff) this spec's
  forms rate-limiter borrows the shape of (a simpler fixed-window variant, §10).
- `e()` (`admin/app.py:404`) is the HTML-escaping helper every rendered page already uses; anything this spec
  renders into an admin-panel page (a stored form submission, a webhook delivery log line) MUST go through it
  — a stored submission is attacker-controlled text.

**Forgejo (already shipped, `scripts/apps/forgejo.sh`):**
- `FORGEJO_PORT` (default 9128, loopback), `FORGEJO_HOST="git.${DOMAIN}"`: `scripts/apps/forgejo.sh:90-91`.
- `INSTALL_DIR=/opt/forgejo` (userland path), `DATA_MOUNT="${INSTALL_DIR}/data"`: `scripts/apps/forgejo.sh:92,94`.
- `[repository] ROOT = ${DATA_MOUNT}/repositories` → bare repos live at (userland path)
  `/opt/forgejo/data/repositories/<owner>/<repo>.git`, i.e. (host path, same `PD_BASE` pattern as
  `lib-sites.sh`) `${PD_BASE}/debian/opt/forgejo/data/repositories/<owner>/<repo>.git`:
  `scripts/apps/forgejo.sh:247`.
- The full hardened `app.ini` heredoc (`scripts/apps/forgejo.sh:216-297`) has **no `[webhook]` section at
  all** — confirmed by reading the entire block. This matters: Forgejo's own default for
  `[webhook] ALLOWED_HOST_LIST` is `external` (verified against Forgejo's own docs, §16-EXT-1), which
  **rejects a webhook target on loopback/127.0.0.1 by default**. §10's AD-6 covers the fix.
  `app.ini` is written idempotently — kept as-is if `HTTP_ADDR = 127.0.0.1` is already present
  (`scripts/apps/forgejo.sh:209-211`) — so an *existing* Forgejo install will **not** pick up a new
  `[webhook]` block automatically; §10 flags the required one-time re-seed step.
- Auth model: `git.${DOMAIN}` sits behind Cloudflare Access by default, and git-over-HTTPS/the REST
  API/LFS **cannot follow a 302-to-login** — the operator must already have carved out a CF Access
  service-token exemption for `git.${DOMAIN}` for `git push` itself to work at all
  (`docs/FORGEJO.md:48-62`). This is a pre-existing, already-documented operator dependency, **not** a new
  one this spec introduces — the webhook *delivery* itself never touches Cloudflare Access at all (it fires
  from Forgejo, in the userland, to the admin panel's loopback bind, sharing the phone's network namespace
  with proot — same "Termux-native + proot share one loopback" model the whole stack already runs on).

**Email (already shipped):**
- Maddy's outbound submission listener: `submission tcp://127.0.0.1:${MAIL_SUBMISSION_PORT}` requiring SMTP
  AUTH (`insecure_auth yes` because it's loopback-only): `scripts/email/maddy.conf.tmpl:72-85`.
  `MAIL_SUBMISSION_PORT` default `9587`: `scripts/steps/85-install-email.sh:68`.
- `scripts/email/mail-drain.py:306-327` (`inject()`) is the exact, already-working `smtplib` pattern against
  a Maddy loopback listener: `smtplib.SMTP(host, port, timeout=...)` → `ehlo()` → `starttls()` if offered →
  `login(user, pass)` → `sendmail(...)`. This spec's forms-email-relay reuses this pattern verbatim against
  the **submission** port instead of the inject port.
- `docs/EMAIL.md`/`scripts/steps/85-install-email.sh:64-70,188,216` establish the `mail_user()` /
  `MAIL_ADMIN_LOCALPART` role-mailbox convention (`admin@${MAIL_DOMAIN}` funnels role mail) this spec reuses
  as the default forms-relay recipient.

**Caddy / logging:**
- JSON access logging is already a 3x-repeated pattern (`format json`, `roll_size 10MiB`, `roll_keep 5`,
  written to `/var/log/pocket/<name>-access.log` inside the userland): the core chat vhost
  (`config/Caddyfile.tmpl:33-47`), the landing portal (`scripts/landing/landing.caddy.tmpl:90-96`), and the
  MCP vhost (`scripts/mcp/mcp.caddy.tmpl:57-58`). `/var/log/pocket` inside the userland is bind-mounted from
  `${POCKET_LOG_DIR}` on the host by `start-stack.sh` (`scripts/start-stack.sh:59-64`), so a new
  `sites-access.log` lands host-side, Termux-natively readable with zero proot round-trip — the exact same
  arrangement `honeypot-watcher.py` already depends on for `caddy-access.log`.
- The **exact** JSON schema this repo's own code already parses in production —
  `scripts/honeypot/honeypot-watcher.py:469-507` (`parse_line()`) — is `{"ts": <epoch>, "status": <int>,
  "request": {"client_ip", "remote_ip", "host", "uri", "method", "headers": {"User-Agent": [...],
  "Cf-Connecting-IP": [...]}}}`. This spec's analytics parser reuses this exact, already-proven-against-real-
  traffic field set rather than assuming any additional Caddy JSON fields (`duration`/`size`) that aren't
  independently confirmed against this repo's own logs (§15).
- Caddy's directive **sort order** (not source order) decides evaluation order for same-block directives:
  `respond` sorts before `reverse_proxy`, which sorts before `file_server`; `handle`/`route` sort earliest of
  all (verified against Caddy's own docs, §16-EXT-2). This is load-bearing for §10's forms-vhost design.

**SQLite-on-derived-database precedent:** `scripts/honeypot/honeypot_db.py` is the established pattern for
"a small SQLite DB, sole-writer, WAL + `synchronous=NORMAL` + `busy_timeout=5000`, ext4 only, never exFAT"
(`honeypot_db.py:9-15,73-120,148-152`). This spec's forms feature reuses this shape directly (§9); analytics
deliberately does **not** (§11's AD explains why).

**HMAC precedent:** `hmac.new(key, msg, hashlib.sha256).hexdigest()` + `hmac.compare_digest(...)` is already
used for four independent signing/verification needs in this repo: the auth-gateway's session/state
signing (`scripts/gateway/matrix-auth-gw.py:264,418,542,554-555`), the sticker backend's URL-signing
(`scripts/sticker/sticker-backend.py:114,123,143`), the offsite-S3 SigV4 signer (`scripts/ops/offsite-s3.py:71,115`),
and CSRF/password checks in the panel itself (`admin/app.py:440,2766-2767`). This spec's webhook HMAC
verification (§10) is a fifth application of the same idiom, not a new cryptographic pattern.

**Termux ecosystem (host prereqs):** `termux-api` is installed as an optional, non-fatal host package
(`scripts/steps/00-prereqs.sh:29,33`); the only commands this repo currently calls are `termux-battery-status`
(`admin/app.py:1194`, `scripts/ops/metrics-sampler.py:144-151`), `termux-wake-lock` (no args,
`scripts/start-stack.sh:46`, `scripts/steps/00-prereqs.sh:82-83`), and `termux-job-scheduler`
(`scripts/steps/75-install-boot.sh:79-118`, the watchdog registration). §8 covers the new capability research
this spec had to do beyond that existing footprint.

## 5. Cross-cutting architecture decisions

### AD-1 — zero new supervised processes; both new inbound surfaces ride the existing admin gunicorn worker

Every one of the four features is designed to add **no new long-running process**, per the hard product
constraint (3–4 GB RAM, no root, battery-sensitive). Concretely:

- **Webhook receiver** and **forms receiver** are new Flask **routes** inside the already-running,
  already-supervised `admin/app.py` gunicorn worker (`scripts/steps/70-install-admin.sh`) — not a new
  listener, not a new port, not a new `supervise` entry. This is a direct extension of the pattern
  `sites_upload()` already established: the panel already accepts large, untrusted-shaped inbound content
  (a zip upload) on this exact process.
- **Analytics-lite** is on-demand computation triggered by a panel page view (or an MCP/CLI call), cached
  with a short TTL exactly like `gather_stats_cached()`/`_site_probes()` already do — never a tailing daemon.
  Unlike `honeypot-watcher.py` (which genuinely needs to be a live tailing process because its job is
  *real-time* alert/block dispatch), analytics has no real-time obligation — "how many hits did my blog get
  today" tolerates being a few minutes stale, so there is no equivalent justification for a second daemon.
- **Share-sheet deploy** is a **local, interactive, on-phone script** the operator explicitly taps to run
  (§8) — it is not a listener at all, it runs once, does its work, and exits.

**Why not a second small process for the two new inbound endpoints instead of extending the admin panel?**
A dedicated tiny process would isolate public form-traffic from the operator's private admin console at the
cost of: a second gunicorn/http.server process (RAM), a second supervise entry + pidfile + log +
crash-respawn wiring (`scripts/lib/common.sh`'s `supervise`, currently used by ~15 services per the repo's
own inventory), and a second place every future security review has to look. Given the phone's RAM ceiling
and the "new long-running processes need strong justification" constraint, reusing the one process already
paid for is the better trade for a single-operator deployment — accepted as a named trade-off, not a free
lunch: if the admin panel process is ever under heavy operator-side load (a big detached backup, say), public
form/webhook traffic shares its four gthreads. This is flagged as OQ-1 (§14) for the operator to bless or
reject.

### AD-2 — every new flag requires `ENABLE_SITES=true`, fails closed at install time if not

`ENABLE_SITES_WEBHOOKS`, `ENABLE_SITES_WIDGET_DEPLOY`, `ENABLE_SITES_FORMS`, `ENABLE_SITES_ANALYTICS` are
four new, independent, off-by-default flags (per the task brief's explicit requirement). All four are
*sub*-features of the sites module, not standalone apps, so `scripts/apps/sites.sh` (already the sole
installer for the module, already idempotently re-runnable) asserts each enabled sub-flag also has
`ENABLE_SITES=true`, and `die`s with a clear message otherwise — mirroring how `86-install-webmail.sh`
depends on `ENABLE_EMAIL` (grepped: `.env.example` groups "Webmail (the UI half; shares ENABLE_EMAIL)" at
`.env.example:521`). No new top-level `app_order`/`app_step` entry is added to `scripts/install.sh` — these
four flags are read and acted on **inside** the existing `SITES` step (`scripts/install.sh:83`,
`[SITES]="apps/sites.sh"`), consistent with `sites.sh`'s own doc comment that it is safe to re-run.

### AD-3 — reserved forms/webhook paths and hostnames never collide with a deployed site's own content

Two new "virtual" surfaces are added under the sites module's namespace: the forms POST path
(`/__pocket-forms__/...`, §10) lives *inside* every site's own URL space, and the webhook/secret-management
routes live under the *panel's* `/sites/<name>/...` namespace (already reserved — it's the admin panel, not
a served site). The forms path is deliberately **not** a dotfile path (so it doesn't accidentally interact
with the `@dot` 403 guard, §4) and uses a double-underscore convention that is vanishingly unlikely for a
real site to have deployed a file at by accident; `docs/SITES.md` gets an explicit callout that this path
segment is reserved (§13).

### AD-4 — new derived state stays on ext4, never the exFAT SD card

Consistent with every existing derived-state store in this repo (`honeypot.db`, `metrics.jsonl`,
`admin-audit.log`, the sites registry itself), the forms SQLite DB and the per-site webhook-secret files live
under `${POCKET_STATE_DIR}` (ext4, `$HOME`-rooted) — never under `DATA_DIR` (often exFAT, per
`honeypot_db.py:10-12`'s explicit warning that "SQLite WAL/locking misbehaves on exFAT").

### AD-5 — Caddy vhost edits stay feature-enable-time only, never per-request or per-deploy

SPEC-SITES-PIPELINE AD-1's invariant — "per-site deploys are pure filesystem operations, Caddy is never
touched per deploy" — is preserved exactly. Two of the four M4 features touch `sites.caddy.tmpl` (analytics'
`log` block, forms' reverse-proxy matcher), but both are **one-time, install/feature-toggle-time** edits to
the ONE wildcard vhost (re-applied by re-running `apps/sites.sh`, exactly like `SITES_SPA_MODE` already
works, `scripts/apps/sites.sh:72-92`) — never a per-site, per-deploy, or per-submission Caddy change. The
webhook feature touches **no** Caddy config at all (§10).

## 6. Feature A — Git-push-to-deploy (Forgejo webhooks)

### 6.1 User story

*As the operator, I `git push` to a repo I created on my own bundled Forgejo. Within a few seconds, the
pushed content is live at `<site>.<DOMAIN>` — no manual zip, no panel click, no MCP call.*

### 6.2 Architecture / data flow

```
operator's laptop --git push--> git.${DOMAIN} (Forgejo, loopback :9128, behind CF Access + service-token
                                                exemption per docs/FORGEJO.md — pre-existing, unchanged)
                                       |
                                       | Forgejo (in-userland process) fires its OWN configured webhook,
                                       | over LOOPBACK, to the admin panel's OWN loopback bind — this call
                                       | shares the phone's network namespace (proot) and NEVER touches
                                       | Caddy, the CF Tunnel, or CF Access at all.
                                       v
                        POST http://127.0.0.1:${ADMINWEB_PORT}/sites/<site>/webhook/forgejo
                        headers: X-Forgejo-Event: push, X-Forgejo-Signature: <hex hmac-sha256(body)>
                        body: JSON push-event payload (ref, after, repository.full_name, ...)
                                       |
                                       v
                admin/app.py: verify HMAC (site's own secret) -> filter to configured branch ->
                validate repository.full_name (regex + realpath-containment under the Forgejo repos root) ->
                validate `after` commit SHA (hex regex) -> per-site cooldown check
                                       |
                                       v (synchronous, bounded timeout — mirrors sites_upload()'s
                                          synchronous "stream to .staging/" step)
                scripts/sites/webhook-stage.sh <site> <owner/repo> <sha> --job <id>
                  -> proot-distro login debian -- git -C <bare-repo>.git archive --format=zip
                       -o /var/www/sites/.staging/webhook-<job>.zip -- <sha>
                                       |
                                       v (detached — mirrors sites_upload()'s final step exactly)
                run_script_detached_argv("sites/site-deploy.sh",
                    [site, staged_zip, "--build", <resolved from registry>, "--job", job_id], ...)
                                       |
                                       v
                          EXISTING M1 pipeline (unchanged) -> site live
```

The webhook receiver's only two responsibilities are **authenticate** and **stage**; everything after
`site-deploy.sh` is invoked is the exact, already-hardened M1 pipeline. No new deploy logic, no new
build-tier logic, no new atomic-swap logic.

### 6.3 Ground-truth finding: Forgejo's default webhook config would reject a loopback target

Forgejo's `[webhook] ALLOWED_HOST_LIST` (a security control against webhook-driven SSRF) defaults to
`external`, meaning Forgejo's outbound webhook HTTP client refuses to connect to loopback/private
targets *unless the config explicitly allows it* (verified against Forgejo's own admin config-cheat-sheet
docs, §16-EXT-1: possible values include `loopback`, `private`, `external`, `*`, or explicit CIDRs/wildcards).
`scripts/apps/forgejo.sh`'s shipped `app.ini` (`:216-297`) has no `[webhook]` section at all, so this default
applies. **A Forgejo webhook pointed at the admin panel's loopback bind will silently fail (or error, per
Forgejo's UI) until this is fixed.**

### AD-6 — add `[webhook] ALLOWED_HOST_LIST = loopback` to the app.ini template, with an explicit re-seed step for existing installs

**Decision:** extend the `app.ini` heredoc in `scripts/apps/forgejo.sh` with:

```ini
[webhook]
; Pocket Pages M4: the git-push-to-deploy webhook target is the admin panel's OWN
; loopback bind (127.0.0.1) -- Forgejo's SSRF guard defaults to "external" and
; would otherwise refuse to deliver there. Scoped to loopback ONLY (not "private"
; or "*") -- this repo's threat model never needs Forgejo to reach anything else.
ALLOWED_HOST_LIST = loopback
```

Because `scripts/apps/forgejo.sh` deliberately preserves an *existing* hardened `app.ini` rather than
clobbering it (`:209-211`, "never clobber operator edits / Forgejo rewrites"), this new stanza will **not**
retroactively appear on a phone that installed Forgejo before M4. The fix mirrors the existing
loopback-bind assertion pattern (`:305-312`): after the idempotent app.ini seed/keep block, add a
**separate, always-run** assertion that greps for `ALLOWED_HOST_LIST` under `[webhook]` and, if absent,
appends the stanza in place (a small `awk`/`grep -q || printf >>` idiom — the same "assert or heal" shape
`RESERVED_SUBS` duplication is *not* auto-healed for, but a one-line INI append is safe to auto-heal because
it can only ever *widen* what Forgejo already trusted, and its value space is a small fixed allowlist the
installer itself controls, not operator data). This applies on every `apps/forgejo.sh` re-run (idempotent),
so upgrading to M4 and re-running the installer (or the panel's "reapply" flow, if forgejo ever gains one)
is sufficient — no manual edit required, unlike the CF Access service-token exemption (which stays
operator-side, unchanged, per `docs/FORGEJO.md:55-62`).

### 6.4 File-by-file changes

**New: `scripts/sites/webhook-stage.sh <site> <owner/repo> <sha> [--job <id>]`**
- Sources `lib/common.sh` + `lib-sites.sh` exactly like every other `sites/*.sh` entry point.
- `validate_site_name "${site}"` (reuses `lib-sites.sh:94-116` unmodified).
- Validates `<owner/repo>` against `^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$` (no path separators
  beyond the one literal `/`, no `..`), then computes
  `${PD_BASE}/debian/opt/forgejo/data/repositories/<owner>/<repo>.git`, realpath-resolves it, and requires
  the result to (a) stay under the repositories root and (b) exist as a directory — the same
  regex-then-realpath-containment-then-existence three-layer discipline `validate_release_id()` already
  applies to release ids (`lib-sites.sh:123-132`) and MCP's staged-path check applies to upload paths
  (SPEC-MCP-COMPLETION §5.3).
- Validates `<sha>` against `^[0-9a-f]{40}$` (a full, lowercase, 40-hex-char git object id) — chosen
  specifically because a hex-only charset makes git-argument-injection (a ref/tree-ish starting with `-`
  being misparsed as a flag) structurally impossible, unlike a branch name.
- Runs (in the userland, mirroring `build_hugo`'s exec pattern, `site-deploy.sh:204-205`):
  `proot-distro login debian -- bash -lc "git -C '<repo>.git' archive --format=zip -o
  '/var/www/sites/.staging/webhook-<job>.zip' -- '<sha>'"`, timeboxed (`timeout ${SITES_WEBHOOK_STAGE_TIMEOUT:-60}`).
- On success, prints the host-side staged path to stdout (the caller reads it back); on any failure, exits
  non-zero with a clear reason on stderr — the caller (the Flask route) treats this as a synchronous
  precondition failure and responds to Forgejo with a non-2xx before ever touching `site-deploy.sh`.

**New: `scripts/sites/site-webhook-secret.sh <site> [--rotate]`**
- `validate_site_name`, then reads/creates/rotates a 0600 secret file at
  `${POCKET_STATE_DIR}/sites-webhook/<site>.secret` (32 random bytes, `secrets.token_hex(32)`-equivalent via
  `openssl rand -hex 32` — mirroring the existing pattern of shell scripts minting secrets, e.g.
  `rotate-registration-token.sh`). Prints the secret to stdout **once** (mirrors
  `pocket_mint_invite_token`'s "its purpose is to be shared, so it IS returned" convention, and
  `rotate-admin-pass`'s "shown ONCE on the result page" convention, `admin/app.py:265`).
- `--rotate` regenerates unconditionally; without it, an existing secret is reused (idempotent — re-running
  the panel's "show my webhook secret" action doesn't invalidate an already-configured Forgejo webhook).

**Edit: `admin/app.py`**
- New route `POST /sites/<name>/webhook/forgejo` (no `@login_required` — this is an unauthenticated-by-
  password, HMAC-authenticated public-shaped endpoint, exactly like `sites_upload()` is gated by a
  *different* mechanism than the rest of the panel, `admin/app.py:3109-3114`, except the webhook route has
  no session/password concept at all — it is called by a machine, not a browser). Reads the raw body
  (`request.get_data(cache=False, as_text=False)`, capped by the existing `MAX_CONTENT_LENGTH`), computes
  `hmac.new(secret, raw_body, hashlib.sha256).hexdigest()`, and compares against the `X-Forgejo-Signature`
  header with `hmac.compare_digest()` — the same idiom as `csrf_ok_header()` (`admin/app.py:2762-2767`).
  Falls back to also accepting `X-Gitea-Signature` (Forgejo's Gitea-compatibility header, verified alongside
  `X-Forgejo-Signature` in Forgejo's own docs, §16-EXT-1) so an operator's existing Gitea-flavored tooling/
  docs still work; both are checked with the same secret and comparison. Rejects (400) if neither header is
  present or the site has no webhook secret provisioned yet.
- New route `GET /sites/<name>/webhook` (login-required, in-panel) — shows whether a webhook secret exists,
  a "generate/rotate" button (danger-tier-lite: not `DANGER_META` since it only *invalidates* a config the
  operator re-pastes into Forgejo themselves, not a data-destructive action), and the exact webhook URL +
  payload-type instructions to paste into Forgejo's per-repo webhook settings UI.
- `_site_webhook_cooldown_ok(name)` — a small module-level dict (`{site: last_dispatch_ts}`) + lock, same
  shape as `_STATS_CACHE`/`_SITE_HEALTH_CACHE` (`admin/app.py:2934-2938,3917-3919`), rejecting (429) a new
  webhook-triggered deploy for the same site within `SITES_WEBHOOK_COOLDOWN_S` (default 10s) of the last
  one — cheap back-pressure against a misbehaving CI loop or a replayed request, independent of the HMAC
  check.
- Branch filter: parses `payload["ref"]`, compares to `f"refs/heads/{SITES_WEBHOOK_BRANCH}"` (default
  `main`); a mismatch returns `200 {"skipped": "not the configured branch"}` (a **push to a non-deploy
  branch is not a delivery failure** — Forgejo should not see this as an error and retry/alert).
- Build-tier resolution: `_read_sites_registry()["sites"].get(name, {}).get("build", "none")` — reuses the
  *existing* registry read helper (`admin/app.py:2813-2823`) rather than adding a second way to learn a
  site's build tier; a site that has never been deployed by any other channel gets `"none"` (raw static
  content) on its first webhook-triggered deploy, exactly like a brand-new site does today via
  `site-deploy.sh`'s own `mkdir -p` auto-creation (`site-deploy.sh:293-295`).

### 6.5 Config / flags

```
ENABLE_SITES_WEBHOOKS=false     # git-push-to-deploy via the bundled Forgejo's webhooks (needs ENABLE_SITES)
SITES_WEBHOOK_BRANCH=main       # the ONE branch a push to which triggers a deploy (global, not per-site — OQ-3)
SITES_WEBHOOK_COOLDOWN_S=10     # minimum seconds between webhook-triggered deploys for the SAME site
SITES_WEBHOOK_STAGE_TIMEOUT=60  # seconds; hard timebox on the synchronous `git archive` staging step
```

### 6.6 Security analysis

- **Authentication is HMAC over the raw body, not source-IP trust.** Even though the intended caller
  (Forgejo) reaches this route over loopback, loopback is not a trust boundary on Android/Termux — *any*
  app with the `INTERNET` permission can reach a localhost port, which is the exact reasoning
  `maddy.conf.tmpl:54-55` already documents for why its own inject endpoint requires AUTH despite being
  loopback-only. The webhook route inherits that same reasoning verbatim.
- **No shell injection path.** The only two values pulled from the (HMAC-authenticated) JSON body are
  `repository.full_name` (regex-then-realpath-containment-then-existence checked, §6.4) and `after` (strict
  40-hex regex) — both are argv-array elements passed to `git archive`, never string-interpolated into a
  shell command, and the hex-only SHA charset structurally forecloses git's own argument-injection class.
- **No probing oracle.** An HMAC mismatch and an unknown-site 404 both return generically (no "site exists
  but secret is wrong" vs "site doesn't exist" distinction in the response body), mirroring the panel's
  existing "no probing for undeployed names" rule (`admin/app.py:3286-3288`, cited in SPEC-MCP-COMPLETION §11).
- **CF Access is a non-issue for this path**, not because it's disabled, but because the request never
  reaches Cloudflare's edge at all (§6.2) — confirmed via `_cf_access_gate()`'s inertness on header-less
  requests (`admin/app.py:1751-1753`).
- **Existing-site webhooks can only redeploy that site.** The URL path segment (`<name>`) is
  `SITE_SUB_RE`-validated before any registry/filesystem lookup, exactly like every other `/sites/<name>/...`
  route.
- **The Forgejo `[webhook] ALLOWED_HOST_LIST = loopback` change is scoped as tightly as possible** (not
  `private`, not `*`) — Forgejo itself can still only ever be pointed at 127.0.0.0/8 targets by a webhook an
  operator configures through its own admin-gated UI (single-operator model; Forgejo's own
  `DISABLE_REGISTRATION=true`, `scripts/apps/forgejo.sh:263`, means only the operator can create webhooks
  at all).

### 6.7 Failure modes

| Failure | Behavior |
|---|---|
| Wrong/missing HMAC signature | `401`, no site/secret existence disclosed, logged via `log_audit()` |
| Site has no webhook secret provisioned | `404` — operator must visit the panel's webhook page first |
| Push to a non-configured branch | `200 {"skipped": ...}` — not an error, no deploy |
| `repository.full_name` fails validation/containment/existence | `400`, `git archive` never invoked |
| `git archive` fails (bad sha, corrupt repo, timeout) | `502`, deploy never dispatched, job never created |
| Cooldown window not elapsed | `429`, caller (Forgejo) may retry per its own webhook retry policy |
| `site-deploy.sh` itself fails after dispatch | Identical to any other detached deploy failure — visible via
  the job state file / the panel's existing deploy-log SSE / `pocket_site_status` (M3) — **not** reported
  back to Forgejo, since the HTTP response already returned 200 once staging+dispatch succeeded (Forgejo's
  webhook delivery contract only covers "was the webhook received", not "did the eventual deploy succeed") |
| Forgejo's `ALLOWED_HOST_LIST` fix didn't reach an already-installed Forgejo | Webhook creation in Forgejo's
  UI (or delivery) fails with an SSRF-guard error; `docs/FORGEJO.md` gets an upgrade note (§13) |

### 6.8 Test plan

**Unit (`tests/test_sites_webhook.py`, stdlib-first, pytest):**
- HMAC verify: correct secret/body → accept; wrong secret → reject; wrong body (tampered) → reject; missing
  header → reject; `X-Gitea-Signature` fallback accepted with the same secret.
- `repository.full_name` validation: valid `owner/repo` accepted (against a tmp-fixture bare-repo tree
  standing in for the Forgejo repositories root); `../../etc` / absolute paths / embedded-newline / more
  than one `/` all rejected before any filesystem touch — mirrors `tests/test_pipeline.py`'s own
  `test_staging_containment_rejects_path_outside_staging` shape (`tests/test_pipeline.py:414-429`, cited by
  SPEC-MCP-COMPLETION §12 for the identical pattern).
- `sha` validation: 40 lowercase hex accepted; short/uppercase/non-hex/`-`-prefixed all rejected.
- Branch filter: `refs/heads/main` (default) dispatches; `refs/heads/feature-x` skips; `refs/tags/v1` skips.
- Cooldown: two dispatches within `SITES_WEBHOOK_COOLDOWN_S` → second is 429'd; a monkeypatched
  `run_script_detached_argv` asserts it is called exactly once.
- `webhook-stage.sh` as a subprocess test (mirrors `test_pipeline.py`'s real-subprocess approach): a fixture
  bare git repo with one committed file, archived at its own `HEAD` sha → the resulting zip, when
  safe-extracted, matches the committed content.

**Needs the arm64 E2E:** a real Forgejo instance + a real webhook delivery (loopback, in-userland) → the
existing site-deploy E2E assertions (200 on the site's Host header, exact-vhost precedence unaffected)
applied via the webhook path instead of the panel upload path; the `[webhook] ALLOWED_HOST_LIST` fix
verified by actually creating a webhook in Forgejo's UI and confirming delivery succeeds (this is the one
assertion that genuinely cannot be faked without a real Forgejo binary).

## 7. Feature B — Share-sheet deploy (Termux:API) — verified-capability findings and revised design

### 7.1 The brief, as given

*"Share-sheet deploy via Termux:API — 'Share → pocket-homeserver' from any Android app sends a zip/folder
into a deploy."*

### 7.2 Capability verification (§16-EXT-3..6) — ⚠ SUPERSEDED BY CORRECTION C-1 (top of file): item 3 below is factually wrong (termux-app DOES register ACTION_SEND via FileShareReceiverActivity), so the "not achievable" conclusion is inverted; the share-hook design in C-1 is the operative one

The task instructions require verifying Termux:API capabilities before designing on them rather than
asserting from memory. Research (external, since nothing in this repo exercises share-target registration —
its only Termux:API usage is calling `termux-battery-status`/`termux-wake-lock`/`termux-job-scheduler`, §4):

1. **`termux-api-package`'s full command list** (55 scripts, fetched from
   `github.com/termux/termux-api-package`) contains no share-*receiving* primitive. `termux-share` — the one
   command whose name suggests it — is confirmed **outbound-only**: its own usage text is *"Share a file
   specified as argument ... to a chooser"* (§16-EXT-4) — it makes Termux the **source** of an Android
   `ACTION_SEND`, not the **destination**.
2. **The Termux:API Android app's `AndroidManifest.xml`** (`github.com/termux/termux-api`) has no
   `ACTION_SEND` intent-filter anywhere (§16-EXT-5) — it does not register as a Share Sheet target.
3. **The base Termux app's `AndroidManifest.xml`** (`github.com/termux/termux-app`) also has no
   `ACTION_SEND` intent-filter. It does export a `RunCommandService` responding to a Termux-specific custom
   action (`${TERMUX_PACKAGE_NAME}.RUN_COMMAND`), gated behind a `dangerous`-protection-level permission
   (§16-EXT-6) — this is the mechanism Termux:Widget/Termux:Tasker use, but it requires the **calling** app
   to know about and construct that specific intent; an arbitrary photo/file app's generic "Share" button
   only ever offers `ACTION_SEND` to whatever registered for it, which is neither Termux nor Termux:API.

**Conclusion: genuine "Share → pocket-homeserver" from an arbitrary Android app's native Share button is not
achievable with Termux + Termux:API alone.** Building it for real would require shipping a small companion
Android app with its own `ACTION_SEND` intent-filter that forwards the received content into Termux via
`RUN_COMMAND` — a new Android/Kotlin project with its own build tooling, signing, and distribution story,
which is unambiguously out of scope for a bash+Python self-hosted-stack repo. This spec does **not** design
that companion app; it is named as a real v1.2-or-later idea in §3's non-goals and flagged for the operator
in §14 (OQ-2).

### 7.3 Revised design — a genuinely verified, one-tap, on-phone deploy path

**Decision: ship the closest honest approximation using only verified capabilities, and correct the
feature's framing rather than its substance.** `termux-storage-get` (`termux-api-package`, §16-EXT-4)
verifiably opens Android's Storage Access Framework document picker and copies the chosen file into a
path the calling script names — this is a genuine, already-shipped-elsewhere-in-the-ecosystem, Termux-native
capability. Paired with `termux-dialog` (text-input prompt) and `termux-toast`/`termux-notification`
(completion feedback) — all confirmed present in the same 55-command list — and Termux:Widget's `~/.shortcuts/`
home-screen-icon mechanism (a **separate**, well-known companion app in the same family as Termux:Boot,
which this repo already documents as an operator-installed add-on for reboot survival,
`scripts/steps/75-install-boot.sh:17-18`; confirmed to execute scripts in a real foreground Termux session so
`termux-*` commands behave normally, §16-EXT-7), the buildable feature is: **a home-screen widget icon that,
tapped, opens the system file/document picker, lets the operator choose a zip from anywhere on the device
(including a file they just saved there *from* another app's own Share action — a two-step flow, not
one-tap), prompts for a site name, and deploys it — entirely on-device, no panel, no network hop.**

This is materially different from the brief's literal description and is called out explicitly rather than
silently substituted. §14 OQ-2 asks the operator to bless this framing (and rename the feature accordingly
in docs/UI) or descope it from M4 entirely.

### 7.4 Architecture / data flow

```
operator taps the "Pocket Pages: deploy" Termux:Widget icon on their home screen
        |
        v (runs in a REAL Termux foreground session, per §16-EXT-7)
~/.shortcuts/pocket-deploy-widget.sh
        |
        +-- termux-dialog -t "site name" (text input; validated against SUB_RE before use)
        |
        +-- termux-storage-get <tmp-path>   (opens the system SAF picker; operator picks a .zip)
        |
        +-- bash scripts/sites/site-deploy.sh <site> <tmp-path>
        |     (runs the UNMODIFIED M1 pipeline directly, CLI-style, from a REAL tty --
        |      site-deploy.sh's own staging-containment check is exempt for an interactive
        |      caller, scripts/sites/site-deploy.sh:84-94 -- exactly the documented
        |      "CLI convenience" carve-out, not a new bypass this spec invents)
        |
        +-- termux-toast / termux-notification  (success/failure feedback)
```

Because this script runs the pipeline **directly and locally**, it needs no HTTP call, no panel
authentication, no HMAC, and no new server-side code at all — it is pure client-side convenience wrapping
the exact same CLI path `docs/SITES.md` already documents (`docs/SITES.md:36-51`).

### 7.5 File-by-file changes

**New: `scripts/sites/pocket-deploy-widget.sh`**
- `#!/data/data/com.termux/files/usr/bin/bash` (Termux:Widget scripts run as plain executables, not
  necessarily sourced through a login shell — matching the shebang convention Termux's own ecosystem docs
  use).
- Guards: `command -v termux-storage-get >/dev/null || { termux-toast 'Termux:API not installed'; exit 1;
  }` (mirrors `doctor.sh`'s existing style of checking `termux-wake-lock`/`termux-job-scheduler` presence
  before depending on them, `scripts/ops/doctor.sh:111-116`).
- Prompts for a site name via `termux-dialog -t text`; validates client-side against the SAME `SUB_RE`
  shape as the pipeline (belt-only — `site-deploy.sh` is still the authoritative gate) before ever calling
  `termux-storage-get`, so a bad name fails fast without making the operator pick a file first.
- Calls `termux-storage-get "$TMP_ZIP"`, checks the result is a non-empty file ending in `.zip` (a
  directory pick isn't representable through this picker — noted as a real, accepted limitation, not
  hidden).
- Invokes `bash "${POCKET_ROOT}/scripts/sites/site-deploy.sh" "$SITE" "$TMP_ZIP"` and relays the exit code
  via `termux-toast`/`termux-notification`.
- Cleans up the temp copy on exit (trap).

**Edit: `scripts/apps/sites.sh`** — when `ENABLE_SITES_WIDGET_DEPLOY=true`, `mkdir -p ~/.shortcuts` and
copy (not symlink — Termux:Widget's own docs recommend real files it can stat reliably) `pocket-deploy-widget.sh`
into `~/.shortcuts/pocket-deploy.sh`, `chmod +x`. Prints closing-notes instructions: install Termux:Widget
from F-Droid (same distribution channel this repo already points operators to for Termux:Boot,
`scripts/steps/75-install-boot.sh:81`), long-press the home screen → Widgets → Termux:Widget → add the
"pocket-deploy" shortcut, grant the "All files access"/storage permission Termux itself needs for
`termux-storage-get` to read from arbitrary apps' SAF providers.

**Edit: `.env.example`, `docs/SITES.md`** — new flag + an honestly-named "one-tap deploy from your phone"
section (not "Share Sheet"), including the two-step reality (save/share the file somewhere first, then tap
the widget) and the v1.2-roadmap note about a real Share Sheet companion app.

### 7.6 Config / flags

```
ENABLE_SITES_WIDGET_DEPLOY=false   # on-phone one-tap deploy via a Termux:Widget shortcut (needs ENABLE_SITES
                                    # + the separately-installed Termux:Widget app; NOT an Android Share Sheet
                                    # integration -- see docs/SITES.md)
```

No `SITES_WIDGET_*` tuning knobs are needed — this is a fixed, single-purpose interactive script.

### 7.7 Security analysis

- **No new attack surface at all.** This is a local script an authenticated Android-device user explicitly
  taps; it makes no network listener, accepts no remote input, and calls the exact same `site-deploy.sh`
  entry point the documented CLI path already uses. The only "input" is whatever file the *operator
  themselves* picks via the OS's own trusted file picker.
- **Site-name validation is client-side-first but not client-side-only** — `site-deploy.sh`'s own
  `validate_site_name()` remains the authoritative gate (§4), so a bug in the widget script's regex can
  degrade UX (a rejected deploy) but never bypass the pipeline's own checks.
- **No credential handling whatsoever** — unlike every other new surface in this spec, this feature has no
  secret, no HMAC, no session. It inherits the operator's own device-level trust (whoever holds the unlocked
  phone can already run any command in Termux directly).

### 7.8 Failure modes

| Failure | Behavior |
|---|---|
| Termux:API not installed | `termux-toast`/plain-echo error before any file picker opens |
| Termux:Widget not installed / no shortcut added | The widget icon never appears — an install-time doc note, not a runtime failure |
| Operator picks a non-zip / cancels the picker | Script exits cleanly with a toast, no partial state |
| Invalid site name typed | Rejected before the file picker opens (fail fast) |
| `site-deploy.sh` itself fails (bad zip, reserved name, etc.) | Its own exit code/message is relayed via `termux-toast`; nothing new to fail here — same failure surface as the CLI path already has |

### 7.9 Test plan

Almost entirely **not laptop-testable** — this script's entire value is orchestrating Termux:API commands
that don't exist off-phone, the same caveat `docs/MCP.md`/SPEC-MCP-COMPLETION §12 already accept for the
Hugo/Node build tiers. What laptop CI *can* still check: `shellcheck` (already a CI gate, no new exclusion
needed), and a pure-bash unit test of the client-side site-name regex (extracted into a tiny sourceable
function so `tests/test_pipeline.py`-style subprocess assertions can exercise it without any `termux-*`
binary present). The arm64 E2E harness runs on emulated hardware with no Termux:API/Termux:Widget stack
either (§16, verification gap) — this feature's real validation is a **manual, on-device** smoke test the
operator performs once before the release is cut, documented as such rather than claimed as automated.

## 8. Feature C — Netlify-Forms clone

### 8.1 User story

*As a visitor to one of the operator's static sites, I fill out a plain `<form>` and click submit. As the
operator, I see the submission in my admin panel (and, if I've opted in, get an email) — with zero
client-side JavaScript on the site itself.*

### 8.2 Architecture / data flow

```
visitor's browser --POST /__pocket-forms__/submit/<form>--> <site>.${DOMAIN} (the wildcard Caddy vhost)
                                       |
                                       | Caddy matches the reserved path FIRST (reverse_proxy sorts before
                                       | file_server, verified §16-EXT-2) -- strips any client-forged
                                       | X-Pocket-Site, sets the TRUE one from {labels.__L__}
                                       v
                    reverse_proxy 127.0.0.1:${ADMINWEB_PORT}   (loopback; same admin gunicorn worker as everything else)
                                       |
                                       v
        admin/app.py: read X-Pocket-Site (the site, NOT a client-supplied field) -> cap body size/field
        count/field length -> honeypot-field check -> per-(site,form,ip) rate limit -> INSERT into SQLite
        -> (if ENABLE_SITES_FORMS_EMAIL) relay via Maddy submission port -> redirect/JSON success
                                       |
                                       v
        admin panel: GET /sites/<name>/forms  (login-required) -- an inbox view, e() escaped, paginated
```

### AD-7 — the forms endpoint reverse-proxies from the wildcard vhost into the admin process; header strip-then-set attributes the site, never a client-supplied value
> ⚠ Amended by CORRECTIONS C-2 and C-3 (top of file): the block below additionally carries a
> render-time-minted `X-Pocket-Forms-Gate` token (C-2), the admin vhost strips both custom headers (C-2),
> and the `header_up X-Forwarded-For {client_ip}` line is DROPPED in favor of the panel reading the
> `Cf-Connecting-IP`-preferred chain (C-3).

Caddy's directive sort order (verified §16-EXT-2: `respond` < `reverse_proxy` < `file_server`; `handle`/
`route` sort earliest of all) means a plain, top-level, named-matcher `reverse_proxy @forms ...` line —
**not** wrapped in `handle{}`/`route{}` (the exact construct the SPA-mode comment already warns causes a
*different* ordering hazard, `sites.caddy.tmpl:62-66`) — placed anywhere in the site block will evaluate
before `file_server` regardless of source position, so a coincidentally-deployed real file at
`/__pocket-forms__/...` can never shadow the forms handler, and evaluates disjointly from `@dot`/`respond`
(the forms path contains no dot-segment, so the two matchers never even compete). The new block:

```caddyfile
@forms path /__pocket-forms__/*
reverse_proxy @forms 127.0.0.1:${ADMINWEB_PORT} {
	# Strip any client-forged value BEFORE setting the trusted one -- same
	# strip-then-set discipline as the (currently commented-out) auth-gateway
	# block in landing.caddy.tmpl ("request_header -Remote-User" before
	# forward_auth trusts its own header), applied here via header_up since
	# this is a reverse_proxy block, not a top-level request_header.
	header_up -X-Pocket-Site
	header_up X-Pocket-Site {labels.__L__}
	header_up X-Forwarded-For {client_ip}
}
```

`${ADMINWEB_PORT}` is threaded into `scripts/apps/sites.sh`'s existing `sed` substitution pipeline
(`scripts/apps/sites.sh:95-107`) reading the *already-defined* `.env` var (`.env.example:66`,
`admin/app.py:97`) — no new env var needed for the port itself.

### 8.3 File-by-file changes

**New: `scripts/sites/forms_db.py`** (a module, `import`ed by `admin/app.py`, mirroring `honeypot_db.py`'s
shape rather than its exact code):

```sql
CREATE TABLE IF NOT EXISTS submissions (
    id            INTEGER PRIMARY KEY,
    site          TEXT NOT NULL,
    form          TEXT NOT NULL,
    ts            TEXT NOT NULL,
    ts_epoch      INTEGER NOT NULL,
    ip_truncated  TEXT,           -- /24 (v4) or /48 (v6) truncated, NEVER the full address (AD-8)
    ua            TEXT,
    fields_json   TEXT NOT NULL,  -- {"name": "...", "email": "...", ...} -- honeypot field excluded
    spam          INTEGER NOT NULL DEFAULT 0,
    emailed       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_submissions_site ON submissions(site, ts_epoch);
```

`sqlite3.connect(db_path, timeout=10)` + `PRAGMA journal_mode=WAL`, `synchronous=NORMAL`,
`busy_timeout=5000` — the exact three pragmas `honeypot_db.py:150-152` already establishes as this repo's
concurrent-SQLite-on-ext4 convention. DB path: `${POCKET_STATE_DIR}/sites-forms.db` (AD-4).

**Edit: `admin/app.py`**
- New route `POST /__pocket-forms__/submit/<form>` (no `@login_required` — public by design, same
  authentication-model note as §6.4's webhook route, except here there is deliberately **no** secret at all,
  matching Netlify's own public-form model; the mitigations are structural, §8.5). Reads `X-Pocket-Site`
  (set only by Caddy, §AD-7); 404s if the header is absent (a direct loopback POST to this route bypassing
  Caddy — e.g. from `curl 127.0.0.1:9000` — cannot self-attribute a site and is refused, not guessed).
- Body cap: `request.form` (standard `application/x-www-form-urlencoded` or `multipart/form-data`, the two
  shapes a plain HTML `<form>` without JS can submit) capped at `SITES_FORMS_MAX_BODY_KB`,
  `SITES_FORMS_MAX_FIELDS` field count, `SITES_FORMS_MAX_FIELD_LEN` per-value length — "quotas everywhere a
  byte enters", the exact invariant SPEC-SITES-PIPELINE §11.5 already states for the upload path, applied
  here to form fields instead of zip entries.
- Honeypot field: a fixed, documented field name (`_pocket_hp`) that a legitimate rendered form leaves empty
  (hidden via the site author's own CSS, per `docs/SITES.md`'s forms how-to) — non-empty on receipt marks
  `spam=1` but still **stores** the submission (operator visibility) and **suppresses** the email relay for
  that row (AD-9).
- Rate limit: a module-level `{(site, form, ip_truncated): [timestamps]}` dict + lock, fixed-window,
  default `SITES_FORMS_RATE_LIMIT_PER_HOUR` per key — a simpler, non-backoff cousin of
  `rate_limit_login()`/`_FAILS` (`admin/app.py:464-552`); spam mitigation doesn't need the login path's
  escalating-lockout severity.
- New route `GET /sites/<name>/forms` (login-required) — a paginated inbox (mirrors `honeypot_hits()`'s
  general shape as a filterable table, `admin/app.py:4296`) with every field value passed through `e()`
  (`admin/app.py:404`) before rendering — a stored submission is attacker-controlled text and this is the
  one place it becomes HTML.
- New route `POST /sites/<name>/forms/delete` (login-required, CSRF-checked via the standard `csrf_ok()`
  field-based check, `admin/app.py:451`) for the operator to prune submissions — not `DANGER_META`-tier
  (mirrors `delete-backup`'s non-danger CSRF-only treatment, `admin/app.py:300-308`, not `site-delete`'s
  danger tier — deleting form spam is routine housekeeping, not destroying a whole site).
- Email relay (`ENABLE_SITES_FORMS_EMAIL`, off by default — OQ-4): on a non-spam submission, builds an
  `email.message.EmailMessage`, connects via the exact `mail-drain.py:306-327` pattern
  (`smtplib.SMTP(MAIL_HOST, MAIL_SUBMISSION_PORT)` → `ehlo()` → `starttls()` if offered → `login()` →
  `send_message()`) authenticated as a role account, to `SITES_FORMS_EMAIL_TO` (default
  `admin@${MAIL_DOMAIN}`, reusing the existing role-mailbox convention, `scripts/steps/85-install-email.sh:216`).
  A relay failure is logged and marks `emailed=0`; it never blocks the HTTP response to the visitor (the
  submission is already durably stored in SQLite before the relay is even attempted).

**Edit: `scripts/sites/sites.caddy.tmpl`** — the `@forms`/`reverse_proxy` block (AD-7).

**Edit: `scripts/apps/sites.sh`** — thread `ADMINWEB_PORT` into the template substitution.

**Edit: `docs/SITES.md`** — a "Forms" how-to: the exact `<form>` markup an operator's static HTML needs
(`action="/__pocket-forms__/submit/<form-name>"`, `method="POST"`, the honeypot field), and the reserved-path
callout (AD-3).

### 8.4 Config / flags

```
ENABLE_SITES_FORMS=false            # public form-submission endpoint on every deployed site (needs ENABLE_SITES)
SITES_FORMS_MAX_BODY_KB=64          # per-submission cap
SITES_FORMS_MAX_FIELDS=50           # per-submission field-count cap
SITES_FORMS_MAX_FIELD_LEN=4000      # per-field value length cap (chars)
SITES_FORMS_RATE_LIMIT_PER_HOUR=20  # per (site, form, truncated-ip) fixed window
SITES_FORMS_RETENTION_DAYS=180      # rows older than this are eligible for GC (OQ-5)
ENABLE_SITES_FORMS_EMAIL=false      # relay non-spam submissions by email via Maddy (OQ-4; needs ENABLE_EMAIL too)
SITES_FORMS_EMAIL_TO=               # default: admin@${MAIL_DOMAIN}
```

### AD-8 — privacy stance: truncated IPs only, no raw IP ever persisted, escaping at render time

The brief requires an explicit privacy stance. **Decision:** the submissions table stores `ip_truncated`
(the last octet zeroed for IPv4 — a `/24`; the last 80 bits zeroed for IPv6 — a `/48`, the standard
GDPR-oriented anonymization granularity) computed **before** the INSERT — the full client IP is read once
(from the same `X-Forwarded-For`/`Cf-Connecting-IP` chain the rest of the panel already trusts via
`ProxyFix`, `admin/app.py:369`) and never written to disk in full form, and never logged in full form either
(it doesn't flow through `log_audit()` at all for this route — a deliberate omission, since `log_audit()`'s
existing entries already carry full operator IPs by design, `admin/app.py:408-421`, for a *different*,
already-accepted reason: those are the operator's own metadata, not a third party's, per SPEC-MCP-COMPLETION
§11's own reasoning for `pocket_audit_recent`). What's stored: form field values (whatever the visitor
typed — inherently identifying if they typed their own name/email, which is the visitor's own choice, not
this system's), a truncated IP (coarse abuse-signal only, never fine enough to re-identify), a user-agent
string, and a timestamp. Retention is bounded by `SITES_FORMS_RETENTION_DAYS` (§8's GC, OQ-5 asks the
operator to confirm the default). This stance is documented in `docs/SITES.md`'s forms section so an
operator can accurately describe it to their own site's visitors if legally required to.

### AD-9 — honeypot trip stores but suppresses relay, rather than silently dropping

A silently-dropped submission is indistinguishable (to the visitor) from a successful one, which is
Netlify's own real behavior — but it also means a **false positive** (a legitimate visitor whose browser/
extension autofills the hidden field) vanishes with no operator visibility at all. **Decision:** store
every submission regardless of the honeypot result, tag `spam=1`, filter it out of the default inbox view
(operator can toggle "show spam" the same way `honeypot_hits()` already supports action/rule filters) and
suppress its email relay — giving the operator an audit trail without an inbox full of spam-triggered mail.

### 8.5 Security analysis

- **No CSRF token on the submission route, deliberately.** CSRF matters when an authenticated session
  grants privilege a forged cross-site request could hijack; this route has no session/cookie concept at
  all (a public, anonymous, same-origin form post) — the relevant threats are abuse/spam (honeypot +
  rate-limit, above) and stored-XSS-at-render-time (closed by `e()` on every field, §8.3).
- **Same-origin only, no CORS.** The form's `action` is a path on the *same* site origin the form itself is
  served from (Caddy reverse-proxies internally); this spec adds no `Access-Control-Allow-Origin` header
  anywhere, so a third-party page cannot fetch/submit into another site's forms endpoint cross-origin using
  the visitor's browser in a way that would matter (a plain `<form>` POST from anywhere technically reaches
  the endpoint regardless of CORS — CORS governs *reading the response* cross-origin, not the write itself
  — which is exactly why the honeypot + rate-limit + body caps, not CORS, are the real mitigations here).
- **Quotas everywhere a byte enters** (§8.3's caps) bound worst-case memory/disk cost per submission and per
  hour, on a device with 3–4 GB RAM.
- **The `X-Pocket-Site` trust boundary is Caddy, not the client** — AD-7's strip-then-set discipline is the
  load-bearing check; §16-EXT-2's verified directive-order research is what makes this claim checkable
  rather than asserted.

### 8.6 Failure modes

| Failure | Behavior |
|---|---|
| Missing `X-Pocket-Site` (direct loopback POST bypassing Caddy) | `404` |
| Body/field caps exceeded | `413`, nothing written |
| Rate limit exceeded | `429` |
| Honeypot field non-empty | `200` to the visitor (no signal leaked that it was flagged), stored `spam=1`, no email |
| SQLite write failure (disk full, etc.) | `500` to the visitor, logged; no partial row (single `INSERT`, no multi-statement transaction to leave half-committed) |
| Email relay fails (Maddy down, bad creds) | Submission already stored; `emailed=0`; visitor unaffected; retried on... | never automatically retried in M4 (OQ-6) — logged, operator sees `emailed=0` in the inbox |

### 8.7 Test plan

**Unit (`tests/test_sites_forms.py`):** SQLite schema creation + WAL pragma assertions; field-cap
enforcement (body/field-count/field-length, each independently); honeypot-trip behavior (stored, `spam=1`,
excluded from default query, relay suppressed); rate-limit fixed-window behavior across the hour boundary;
`X-Pocket-Site` requirement (missing → 404, present → attributed correctly); IP truncation correctness
(IPv4 `/24` and IPv6 `/48` fixtures, asserting the FULL address is never present anywhere in the stored
row); `e()`-escaping asserted on the rendered inbox HTML for a submission containing `<script>` in a field
value.

**Needs the arm64 E2E:** a real form POST through the real Caddy wildcard vhost (confirms the `@forms`
matcher wins over `file_server` in practice, not just per Caddy's documented sort order) → row appears in
SQLite → (with `ENABLE_SITES_FORMS_EMAIL=true`) a real message lands in the admin mailbox via the real
Maddy submission port.

## 9. Feature D — Analytics-lite

### 9.1 User story

*As the operator, I open my admin panel and see, per site: request count, approximate unique visitors, a
status-code breakdown, and top paths — for the last N days — with zero JavaScript added to the deployed
site itself.*

### 9.2 Architecture / data flow

```
Caddy (wildcard sites vhost) --format json access log--> ${POCKET_LOG_DIR}/sites-access.log (+ rotated .gz)
                                       |
                                       | operator opens GET /sites/<name>/analytics (or the sites overview
                                       | page shows a compact per-site stat strip)
                                       v
        admin/app.py: _sites_analytics_cached() -- TTL-cached (SITES_ANALYTICS_CACHE_TTL_S) exactly like
        gather_stats_cached()/_site_probes() already are, admin/app.py:2931-2957,3914-3933
                                       |
                                       v (on cache miss only)
        scripts/sites/analytics.py: glob current + rotated (.gz-aware) sites-access.log files within
        SITES_ANALYTICS_RETENTION_DAYS by mtime, parse each JSON line via the EXACT field set
        honeypot-watcher.py:469-507 already proves works against this repo's real Caddy output, bucket by
        request.host's site label, aggregate counts/status/top-paths, compute an in-memory-only truncated-IP
        SET per site for an approximate-unique-visitor count, THEN DISCARD the set (nothing IP-shaped is
        ever written to disk for this feature)
                                       |
                                       v
                          rendered stat cards, per site, in the admin panel
```

### AD-10 — on-demand parse-and-cache, not a daemon and not a derived SQLite ingestion pipeline

Two existing patterns were both considered and rejected in favor of a third, simpler one:

1. **A live-tailing daemon** (like `honeypot-watcher.py`) — rejected per AD-1: analytics has no real-time
   obligation, unlike security alerting.
2. **A derived SQLite ingestion pipeline** (like `honeypot_db.py`, incremental by byte-offset bookmark) —
   rejected as disproportionate for this feature specifically: it would add a *second* SQLite write path
   (alongside forms' new one, §9) purely to answer "how many hits" queries a personal/small-site traffic
   volume does not need indexed server-side filter/sort/pagination for (the exact problem `honeypot_db.py`'s
   own docstring says it solves, `honeypot_db.py:1-7`, for a very different, adversarial, high-volume,
   query-heavy use case). A phone-hosted static site's traffic is not expected to approach a volume where
   re-parsing a ≤50 MB rotated log set (the existing `roll_size 10MiB roll_keep 5` bound, §4) on a
   cache-miss is meaningfully slow.

**Decision:** parse-on-demand, bounded by `SITES_ANALYTICS_MAX_LINES` (a defensive cap independent of file
size, in case a line is pathologically long) and `SITES_ANALYTICS_RETENTION_DAYS` (file-mtime selection),
cached for `SITES_ANALYTICS_CACHE_TTL_S` (default 300s) using the identical module-level-dict-plus-lock
shape `gather_stats_cached()` already establishes. Zero new persistent state.

### AD-11 — the retention window is honest about what raw-log rotation can actually promise

`SITES_ANALYTICS_RETENTION_DAYS` is a **selection filter** over whatever rotated files still exist on disk
— it cannot manufacture history Caddy has already rotated away. Because `roll_size`/`roll_keep` rotate by
**byte size**, not by calendar time, the *effective* retention on a high-traffic site could be much shorter
than the configured day count, and much longer on a quiet one. This spec does not paper over that with a
misleading fixed-window promise; `docs/SITES.md`/the panel UI state the caveat plainly ("history depends on
how much log-rotation headroom your traffic has used"). A calendar-stable daily-rollup ring (mirroring
`metrics-sampler.py`'s JSONL-ring pattern) would fix this properly but is real, separate scope — named as a
v1.2 follow-up rather than silently added here (OQ-7).

### 9.3 File-by-file changes

**New: `scripts/sites/analytics.py`** — a module (also runnable standalone for CLI/testing:
`python3 analytics.py --site <name> --days N`):
- `_iter_log_lines(log_dir, retention_days)`: globs `sites-access.log` + `sites-access*.log.gz` (mirroring
  `honeypot-watcher.py`'s own rotated-log glob + `gzip.open` handling, cited at `honeypot-watcher.py:34-39`'s
  `--scan-history` mode docstring, without adopting its live-tail/offset-bookmark machinery), filtered by
  file mtime.
- `parse_line(line)`: **byte-for-byte the same field extraction** as
  `honeypot-watcher.py:469-507`'s `parse_line()` (ts/status/request.host/uri/method/client_ip via the
  Cf-Connecting-IP-preferred fallback chain) — duplicated rather than imported, since
  `scripts/honeypot/` and `scripts/sites/` are independent, independently-enabled modules and this repo has
  no shared-utility package between app modules today (the same "duplication is the accepted cost of
  independence" trade-off SPEC-MCP-COMPLETION AD-3 already names for `RESERVED_SUBS`'s three-way copy).
- `aggregate(lines, domain)`: buckets by stripping `.{domain}` off `request.host` to recover the site label
  (`SITE_SUB_RE`-validated — a log line with a host that doesn't parse to a valid site label, e.g. a scanner
  probing `foo.bar.` malformed hosts, is silently skipped, not attributed to a site), producing
  per-site: `requests`, `status_2xx/3xx/4xx/5xx`, `top_paths` (capped top-20 by count, path only — no query
  string retained, avoiding accidental capture of query-string PII), `bytes_hint` (best-effort, only if the
  `size` field is present — not asserted as always-present, §15), and `approx_unique_visitors` (the
  in-memory truncated-IP set's cardinality, discarded after the count is taken, AD-12).

**Edit: `admin/app.py`** — `GET /sites/<name>/analytics` (login-required) rendering the aggregate; a compact
stat strip added to the existing `_site_card_html()` (`admin/app.py:2866-2918`) behind
`ENABLE.get("sites-analytics")` (mirroring how the QR-code `<details>` block already sits inside that same
function, `:2910-2916`, as the precedent for "add a `<details>` section to the existing card without
restructuring it").

**Edit: `scripts/sites/sites.caddy.tmpl`** — the `log` block anticipated by the M1 comment
(`sites.caddy.tmpl:29-30`):

```caddyfile
log {
	output file /var/log/pocket/sites-access.log {
		roll_size 10MiB
		roll_keep 5
	}
	format json
}
```

Placed identically to the three existing precedents (`config/Caddyfile.tmpl:41-44`,
`landing.caddy.tmpl:90-96`, `mcp.caddy.tmpl:57-58`) — same `roll_size`/`roll_keep`/`format` values, no new
convention invented. Because this is a SHARED wildcard vhost, this is **one log for every deployed site**,
disambiguated at parse time by `request.host` — never a per-site Caddy config (AD-5).

**Edit: `scripts/apps/sites.sh`** — no substitution changes needed (the `log` block has no placeholders); it
is simply now part of the template `sites.sh` already renders in full on every run.

### 9.4 Config / flags

```
ENABLE_SITES_ANALYTICS=false        # per-site traffic stats parsed from the Caddy access log (needs ENABLE_SITES)
SITES_ANALYTICS_RETENTION_DAYS=30   # file-mtime selection window (see AD-11's caveat -- not a hard guarantee)
SITES_ANALYTICS_MAX_LINES=200000    # defensive cap independent of file size
SITES_ANALYTICS_CACHE_TTL_S=300     # shared-cache TTL (mirrors _STATS_TTL's shape, admin/app.py:3919)
```

### AD-12 — privacy posture: no per-visitor tracking, IP truncation is in-memory-only and never persisted

The brief requires an explicit privacy posture for analytics distinct from forms' (§AD-8), because unlike a
form submission (where the visitor voluntarily typed identifying information), a page view is passive and
the operator never asked the visitor for anything. **Decision:** analytics-lite computes an
**approximate**-unique-visitor count via a truncated-IP (`/24`/`/48`, same granularity as AD-8) `set()`
built **fresh on every cache-miss recomputation** and discarded the moment the aggregate is produced — no
IP, truncated or otherwise, is ever written to any file by this feature. This is stricter than forms'
posture (which does persist a truncated IP, because forms need a per-submission abuse signal across
requests) — analytics only ever needs a **count**, never a **record**, so nothing IP-shaped needs to
outlive one aggregation pass. Combined with "zero client-side JS" (no browser fingerprinting, no cookies,
no third-party beacon), this is a materially more private design than typical third-party web analytics.

### 9.5 Failure modes

| Failure | Behavior |
|---|---|
| `sites-access.log` doesn't exist yet (feature just enabled, no traffic) | Empty aggregate, not an error — mirrors `pocket_metrics`'s "no metrics recorded yet" branch (SPEC-MCP-COMPLETION §7.2) |
| A rotated `.gz` file is corrupt/truncated | Skipped with a warning, not fatal to the whole aggregation |
| A JSON line fails to parse | Skipped (matches `honeypot-watcher.py:476-478`'s own `except: return None` tolerance) |
| `SITES_ANALYTICS_MAX_LINES` cap hit mid-file | Aggregation stops early, result is marked partial (`"truncated": true` in the response) rather than silently under-reporting without a signal |
| Log directory unreadable (permissions) | `500` on the panel route, logged; the rest of the panel is unaffected (isolated try/except, matching `_read_sites_registry()`'s own "degrade, don't raise" convention, `admin/app.py:2813-2823`) |

### 9.6 Test plan

**Unit (`tests/test_sites_analytics.py`):** `parse_line()` against synthetic JSON fixtures shaped exactly
like `honeypot-watcher.py:469-507` expects (including a malformed line, a non-request line, and a line
missing `Cf-Connecting-IP` falling back to `client_ip`); `.gz` rotated-file handling; retention-window
file-selection by mtime; `SITES_ANALYTICS_MAX_LINES` truncation signaling; IP-truncation correctness
(IPv4/IPv6) with an explicit assertion that the aggregate output contains no substring matching a full IP
address; multi-site disambiguation from a single shared log (two hosts, correctly bucketed).

**Needs the arm64 E2E:** a real Caddy wildcard vhost with the new `log` block, real traffic against two
different deployed sites, confirming per-site attribution and rotation (`roll_size`) behavior against the
pinned Caddy binary — the same class of "validate AD-1's Caddy assumptions against the real pinned binary"
E2E phase SPEC-SITES-PIPELINE §12 already runs for the wildcard-vhost host-label mechanism itself.

## 10. Threat model (consolidated)

| Threat | Mitigation |
|---|---|
| Forged webhook delivery | HMAC-SHA256 over the raw body, per-site secret, constant-time compare (§6.6) |
| Webhook replay / runaway CI loop | Per-site cooldown, independent of the HMAC check (§6.4) |
| Git-argument injection via a webhook-supplied ref | Never used — only the 40-hex `after` SHA reaches `git archive`, regex-gated before any subprocess is built (§6.4) |
| Path traversal via `repository.full_name` | Regex + realpath-containment-under-repos-root + existence check, the same 3-layer discipline used everywhere else in this codebase (§4, §6.4) |
| Forgejo SSRF guard silently breaking the feature | Explicit `ALLOWED_HOST_LIST = loopback` addition + idempotent re-assert for existing installs (AD-6) — scoped to loopback only, not widened further |
| Forged `X-Pocket-Site` (site-attribution spoofing on the forms endpoint) | Header strip-then-set at the Caddy layer, verified directive-sort-order makes the forms matcher unconditionally win over `file_server` (AD-7); the route further 404s if the header is absent entirely (no direct-loopback bypass path) |
| Forms spam / abuse | Honeypot field (stored, not silently dropped, AD-9) + per-(site,form,ip) rate limit + body/field/length caps (§8.5) |
| Forms stored-XSS reflected into the operator's admin session | Every field value passed through `e()` before rendering (§8.3), mirroring the panel's blanket escaping convention |
| Visitor/submitter re-identification | IP truncation (forms: persisted at `/24`/`/48`; analytics: computed in-memory only, never persisted, AD-8/AD-12); no client-side JS/cookies/fingerprinting anywhere in this spec |
| Resource exhaustion via any new inbound endpoint | `MAX_CONTENT_LENGTH` (existing, `admin/app.py:366`) + feature-specific caps (`SITES_FORMS_MAX_*`, `SITES_WEBHOOK_STAGE_TIMEOUT`, `SITES_ANALYTICS_MAX_LINES`) on a single gunicorn worker + 4 gthreads |
| A new inbound endpoint monopolizing the admin worker's gthreads, starving the operator's own panel use | Accepted, named trade-off (AD-1), not fully mitigated in M4 — flagged as OQ-1 |
| Unauthorized site mutation via the widget-deploy script | None needed beyond device possession — this feature has no network surface at all (§7.7) |
| Cloudflare Access interaction | Webhook: never touches CF Access (loopback delivery, §6.2); Forms: never touches `admin.${DOMAIN}` at all — the visitor's browser only ever talks to `<site>.${DOMAIN}`, a different, intentionally-public hostname (§8.2) |

## 11. Documentation updates required

Not applied by this spec (single-file-only scope); the M4 implementation must update:

- **`docs/SITES.md`** — new sections: "Git-push-to-deploy" (webhook setup steps, the `[webhook]
  ALLOWED_HOST_LIST` upgrade note for pre-M4 Forgejo installs), "One-tap deploy from your phone" (honestly
  named, not "Share Sheet" — §7.3's framing correction), "Forms" (the `<form>` markup + honeypot field +
  privacy stance), "Analytics" (the retention caveat from AD-11), and the `__pocket-forms__` reserved-path
  callout (AD-3).
- **`docs/FORGEJO.md`** — a cross-reference to the new webhook section + an explicit "upgrading from a
  pre-M4 install" note pointing at the `[webhook]` re-seed step (AD-6).
- **`docs/EMAIL.md`** — a note that the forms feature is a second consumer of the submission port, alongside
  the existing outbound-mail use, for an operator auditing what talks to Maddy.
- **`docs/APPS.md`** — the Pocket Pages row gains a one-line mention of the four new sub-flags.
- **`README.md`** — the brief names this explicitly: the README currently has no Pocket Pages overhaul.
  M4 should add a short "Pocket Pages" feature bullet list (static hosting, admin UI, MCP, QR codes,
  git-push-to-deploy, forms, analytics) at the level of detail the README already gives other subsystems —
  not written here (spec only), but scoped: roughly a paragraph + a bullet list, consistent with the
  README's existing per-feature density, no new screenshots strictly required (existing panel screenshots
  already show the Sites section per M2).
- **`CHANGELOG.md`** — `### Added` entry for M4 once implemented (§12).

## 12. Release plan

Ships as `v1.1.0-pre4` once implemented and arm64-E2E-verified, following the exact cut recipe the M1–M3
prereleases already established (staged commit → arm64 E2E → 4 CI gates green → 0-co-author commit → tag →
`gh` prerelease). M4 is the **last** milestone before the operator-gated FINAL `v1.1.0` tag (per the program
plan) — no M5 sites work is anticipated after this spec beyond whatever the operator raises in review.

## 13. Test plan — arm64 E2E harness extension (consolidated)

Extends the M1/M2/M3 harness (cannot be exercised on the laptop — no `proot-distro`, no real Forgejo/Caddy/
Termux:API binaries) with, in dependency order:

1. Fresh `ENABLE_SITES=true ENABLE_SITES_WEBHOOKS=true ENABLE_FORGEJO=true` install → confirm the
   `[webhook] ALLOWED_HOST_LIST = loopback` stanza is present in the rendered `app.ini`.
2. Create a Forgejo repo + webhook (real UI/API) pointed at the panel's webhook URL with a real secret →
   `git push` → assert the site is live within a bounded time, matching M1's own curl-loop assertion style.
3. Push to a non-configured branch → assert no deploy (job count unchanged).
4. `ENABLE_SITES_FORMS=true` → real form POST through the real wildcard vhost → row in SQLite → (with
   `ENABLE_SITES_FORMS_EMAIL=true`) a real message via the real Maddy submission port.
5. `ENABLE_SITES_ANALYTICS=true` → real traffic against two sites sharing the one wildcard vhost → correct
   per-site attribution, correct rotation behavior at the pinned Caddy binary.
6. Manual, on-device (not automatable in the arm64-qemu harness, which has no Termux:API/Termux:Widget
   stack): the widget-deploy flow, smoke-tested once by the operator before the release is cut (§7.9).

**Laptop smoke (extends the existing gates, no new gate needed):** `shellcheck` on the two new `.sh` files
(already covered by the existing `git ls-files '*.sh'` sweep, `ci.yml`'s shellcheck job); `py_compile` on
`analytics.py`/`forms_db.py` (already covered by the existing `git ls-files '*.py'` sweep); the four new
`tests/test_sites_*.py` files run under the existing `pytest` gate with **no new pip installs** — HMAC,
SQLite, and JSON parsing are all stdlib, and `flask`/`segno` are already installed for `test_panel_sites.py`
(`.github/workflows/ci.yml`, confirmed the `mcp==1.28.0 uvicorn==0.49.0` companion change from M3's AD-10
already landed, so this spec adds zero new CI dependency lines).

## 14. Open questions (for operator approval)

- **OQ-1**: AD-1 routes both new public-shaped inbound endpoints (webhook receiver, forms receiver) through
  the *same* gunicorn worker/gthreads as the operator's own private admin console, rather than a second
  dedicated process. Accept this coupling for M4 (revisit only if it's actually a problem in practice), or
  require a second minimal process now at the cost of more RAM/battery and a second supervise entry?
- **OQ-2** (superseded by CORRECTION C-1): share-sheet deploy IS buildable via the verified
  `~/bin/termux-file-editor` share hook (no companion APK). Bless the C-1 design — share-hook as the
  headline path + the Termux:Widget one-tap flow as a companion, with the honest "the share-sheet entry is
  labeled 'Termux'" caveat and the no-clobber hook-install discipline — or trim to just one of the two
  paths?
- **OQ-3**: §6 makes `SITES_WEBHOOK_BRANCH` a single global default (`main`) rather than per-site. Accept for
  M4, with per-site override as a named follow-up, or is per-site branch configuration important enough to
  build now (it would need a small per-site config file/registry field, a real but bounded diff)?
- **OQ-4**: `ENABLE_SITES_FORMS_EMAIL` defaults to `false` (§8.4) — the brief explicitly calls this out as an
  operator-level decision. Confirm `false` as the M4 default (email relay is opt-in, matching every other
  optional outbound side-effect in this repo), or should forms email default `true` whenever both
  `ENABLE_SITES_FORMS` and `ENABLE_EMAIL` are already true (an "it just works" UX at the cost of a
  surprise-email risk on first enable)?
- **OQ-5**: `SITES_FORMS_RETENTION_DAYS=180` (§8.4) is an invented default with no existing precedent to
  match (unlike e.g. `SITES_KEEP_RELEASES=5`, which had SPEC-SITES-PIPELINE precedent). Is 180 days
  reasonable, or should it be shorter (forms data is more sensitive than release history) — and should GC be
  automatic (a cron/on-demand sweep) or operator-triggered-only in M4?
- **OQ-6**: §8.6 leaves a failed email relay un-retried (`emailed=0`, visible in the inbox, no automatic
  retry). Acceptable for M4 (the submission itself is never lost, only the notification), or is a retry
  worth the added complexity (would need its own small job-state convention, similar in spirit to AD-2 of
  SPEC-MCP-COMPLETION's rejected job-file-for-backup-all idea)?
- **OQ-7**: AD-11 accepts that analytics retention is bounded by Caddy's byte-size-based log rotation, not a
  calendar guarantee, and defers a calendar-stable daily-rollup ring to v1.2. Accept for M4, or is a stable
  "last 30 days" promise important enough to build the rollup now?
- **OQ-8**: Should `git.${DOMAIN}`'s pre-existing CF Access service-token exemption requirement
  (`docs/FORGEJO.md:48-62`, unchanged by this spec) get a more prominent callout specifically in the new
  git-push-to-deploy doc section, given M4 makes `git push` a first-class, marketed workflow rather than an
  incidental one? (Purely a documentation-emphasis question — no code change either way.)

### §14 resolutions (2026-07-19 — conservative defaults under the operator's blanket continue-directive; each vetoable at the pre4 review)

- **OQ-1 → ACCEPT the shared admin-gunicorn worker for M4** (AD-1 stands: no new daemon on a
  3–4 GB phone). Revisit only on observed contention; a dedicated forms/webhook micro-process is a
  named v1.2 candidate, not built now.
- **OQ-2 → BLESS the C-1 design**: share-hook (`~/bin/termux-file-editor`, no-clobber install,
  zip→deploy + non-zip fall-through to `${EDITOR:-nano}`) as the headline path, Termux:Widget one-tap
  as the companion; the "share target is labeled 'Termux'" caveat documented plainly.
- **OQ-3 → global `SITES_WEBHOOK_BRANCH=main` for M4**; per-site branch override = named follow-up.
- **OQ-4 → `ENABLE_SITES_FORMS_EMAIL=false` stands** — opt-in, matching the repo-wide off-by-default
  convention; no surprise email on first enable.
- **OQ-5 → keep 180 days, and make GC AUTOMATIC** (an opportunistic, throttled sweep on insert —
  `DELETE WHERE ts_epoch < cutoff` at most once per day — no new cron): a documented retention
  promise that nothing enforces would be dishonest, and the privacy stance (AD-8) is only real if
  the data actually expires.
- **OQ-6 → no automatic email-relay retry in M4** — the submission is never lost, `emailed=0` is
  visible in the inbox; retry = named follow-up.
- **OQ-7 → ACCEPT rotation-bound analytics retention** with the plain-language caveat (AD-11);
  calendar-stable daily-rollup ring = v1.2 roadmap.
- **OQ-8 → YES** — the git-push-to-deploy doc section gets a prominent callout of the pre-existing
  CF Access service-token exemption requirement (docs-only).

## 15. Explicit non-goals (recap)

See §3 for the full list. Restated for visibility: no Forgejo Actions/CI runners; no non-Forgejo webhook
senders; no literal Android Share Sheet registration (a real gap, not a deferred convenience, §7.2); no
per-site webhook branch config in M4; no CAPTCHA/ML/third-party anti-spam; no long-lived analytics
time-series store; no new supervised process anywhere in this spec.

## 16. Verification I could not perform (appendix)

Listed for a reviewer's benefit — everything below was either verified against an **external** source (not
this repo, so it carries a different confidence class than a `file:line` citation) or genuinely could not be
verified at all:

- **EXT-1 — Forgejo `[webhook] ALLOWED_HOST_LIST` default + values.** Verified via `WebFetch` against
  `forgejo.org/docs/latest/admin/config-cheat-sheet/` (2026-07-19): default `external`; documented values
  `loopback`/`private`/`external`/`*`/CIDR/wildcard. Not independently verified against the actual Forgejo
  15.0.3 binary this repo pins (`scripts/apps/forgejo.sh:83-84`) — the docs site may drift from a specific
  pinned version's exact behavior, though `ALLOWED_HOST_LIST` has been stable across recent Gitea/Forgejo
  releases to the best of available knowledge.
- **EXT-1b — Forgejo webhook signature header.** Verified via `WebFetch` against
  `forgejo.org/docs/latest/user/webhooks/`: `X-Forgejo-Signature` (hex HMAC-SHA256 of the raw body),
  `X-Forgejo-Event`, with `X-Gitea-Event`/`X-GitHub-Event` compatibility headers also present. The exact push
  payload's top-level keys (`ref`, `before`, `after`, `commits`, `repository.full_name`, `pusher`, `sender`)
  were confirmed from the same docs' worked example, not from the pinned binary's actual wire output.
- **EXT-2 — Caddy directive default sort order.** Verified via `WebFetch` against
  `caddyserver.com/docs/caddyfile/directives`: `respond` < `reverse_proxy` < `file_server`; `handle`/`route`
  sort earliest. Not independently re-derived against the exact pinned Caddy version this repo installs (the
  version is referenced elsewhere in this repo's docs but was not re-checked here) — treated as stable
  because it is a documented, versioned Caddyfile-adapter behavior, not an implementation detail likely to
  change silently.
- **EXT-3..6 — Termux:API/Termux ecosystem share-target research.** Verified via `curl`/`WebFetch` against
  `github.com/termux/termux-api-package` (script list), `github.com/termux/termux-api` (AndroidManifest.xml),
  `github.com/termux/termux-app` (AndroidManifest.xml), and the raw source of `termux-share.in`/
  `termux-storage-get.in`. This is source-code-level verification (reading the actual shipped manifest/
  scripts), the strongest confidence class available short of running the APK on a real device — but it was
  not tested on an actual phone as part of this spec's research, only read as source.
- **EXT-7 — Termux:Widget's `~/.shortcuts/` mechanism + execution context.** Verified via `WebFetch` against
  `github.com/termux/termux-widget`'s README. Not tested on-device.
- **Caddy JSON access-log fields beyond what `honeypot-watcher.py` already parses** (specifically `duration`
  and response `size`/byte-count, which analytics' `bytes_hint` field optimistically reads if present, §9.3).
  These are widely documented as part of Caddy's standard `http.log.access` JSON encoder in general Caddy
  literature, but this spec deliberately does **not** treat their presence as guaranteed, because the only
  field set independently confirmed against *this repo's own* production Caddy output is the subset
  `honeypot-watcher.py:469-507` actually reads (ts/status/request.{host,uri,method,client_ip,remote_ip,
  headers}). `bytes_hint` is designed to degrade to absent/null rather than error if the field turns out
  not to be present at whatever Caddy version this repo pins.
- **Whether an existing operator's Forgejo install's `app.ini` file permissions/ownership tolerate an
  in-place `awk`/`printf >>` append** the way AD-6 proposes, versus needing the full `su -s /bin/bash
  ${FORGEJO_RUN_USER}` privilege-drop dance the rest of `forgejo.sh` uses for writes under the data mount
  — `app.ini` itself is chmod'd 600 and chown'd to the run user *after* the heredoc write
  (`scripts/apps/forgejo.sh:298`), so a later append must go through the same `in_debian`/ownership path,
  not a bare host-side file write; this spec states the *what* (append the stanza) but the *exact* privilege
  mechanics of the append should be verified against the live script during implementation, not assumed
  identical to the heredoc-write path which runs before the chown.

## 17. Findings appendix — brief/verified-capability conflicts found during research

Mirrors SPEC-MCP-COMPLETION §14's convention: every place this spec's design diverges from the task brief's
literal wording, with the finding that drove it.

1. **"Share-sheet deploy via Termux:API" is not achievable as literally worded (→ §7).** The brief names
   Termux:API as the mechanism for a native Android Share Sheet target; source-level verification of both
   the `termux-api-package` script list and the `termux-api`/`termux-app` Android manifests found no
   `ACTION_SEND` intent-filter anywhere in this ecosystem. The redesigned feature (Termux:Widget +
   `termux-storage-get` + `termux-dialog`) delivers the closest verifiably-real equivalent, is clearly
   renamed rather than mislabeled, and the gap is escalated to the operator as OQ-2 rather than silently
   downgraded.
2. **Forgejo's webhook SSRF guard would silently break git-push-to-deploy without an app.ini change (→
   AD-6).** Nothing in the M1–M3 specs or the shipped `forgejo.sh` anticipated this — it only surfaced from
   reading the full `app.ini` heredoc (confirming no `[webhook]` section exists) plus external verification
   of Forgejo's own default. Without AD-6, an operator would configure a webhook in Forgejo's UI and it
   would simply never deliver, with no obvious link back to a phone-side config file.
3. **`sites.caddy.tmpl` already named this exact milestone for the analytics log block** (`sites.caddy.tmpl:29-30`)
   — not a conflict, but worth stating plainly: M1's own author anticipated this feature's Caddy change
   precisely, and AD-5/§9.3 execute exactly that anticipated design (same `roll_size`/`roll_keep`/`format`
   values as the three other existing precedents) rather than inventing a new logging convention.
