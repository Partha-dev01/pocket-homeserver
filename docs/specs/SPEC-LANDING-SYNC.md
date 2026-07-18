# SPEC-LANDING-SYNC — landing portal teal re-theme + runtime regen for Pocket Pages

**Status: APPROVED 2026-07-17 (operator) — including OQ-4's new-scope edit to the shipped
`site-delete.sh`. OQ resolutions recorded at the end of §11.**

Milestone: M2 of the Pocket Pages program (ships alongside SPEC-SITES-PANEL).
Depends on: [SPEC-SITES-PIPELINE.md](SPEC-SITES-PIPELINE.md) — M1, APPROVED 2026-07-17 (registry schema §5;
`site-deploy.sh`'s contract in §6 already names a "landing-regen hook (no-op until M2 ships
regen-landing.sh)" call site).
Related: [SPEC-SITES-PANEL.md](SPEC-SITES-PANEL.md) (M2, parallel — no functional dependency between the
two; they're bundled into the same milestone because they touch adjacent parts of the same feature).

---

## 1. Goal

Two independent changes, bundled into one spec because they land in the same file pair
(`scripts/landing/index.html.tmpl` + a new `scripts/landing/regen-landing.sh`):

1. **Re-theme** the landing portal from its current purple/blue aurora palette to the admin panel's teal
   brand, so the public-facing page and the admin panel read as one product.
2. **Add a "your sites" card grid** to the landing page, sourced from the Pocket Pages registry
   (`.registry.json`) and kept fresh automatically on every deploy/delete via a new, install-independent
   `scripts/landing/regen-landing.sh` — the hook M1's `site-deploy.sh`/`site-delete.sh` are already spec'd
   to call.

## 2. Non-goals

- A build-time-shared CSS token file consumed by BOTH `admin/app.py` and `index.html.tmpl` — neither file
  has a build step today (`admin/app.py`'s CSS is a Python string literal; the landing template is
  `sed`/`awk`-substituted bash). Out of scope; a future single-source option is noted in §4 AD-2.
- Per-site opt-out of the public landing listing — proposed as a possible follow-on in §11 OQ-1, but it's a
  schema change to M1's `meta.json` and is **not** decided by this draft.
- Light/dark mode for the landing page. It is deliberately a fixed dark "aurora" aesthetic today (no
  `prefers-color-scheme` block in `index.html.tmpl`, unlike `admin/app.py`'s CSS); this spec does not add
  one — it re-themes the existing fixed-dark look using hues pulled from admin's **dark** token set only.
- Re-theming `scripts/landing/favicon.svg` — cosmetic, deferred.
- Any live/polled health indicator on the landing page's site cards — see §8 AD-8: the landing page has no
  JS backend to poll; live health lives in the admin panel (SPEC-SITES-PANEL §14).

## 3. Current state — the two palettes, side by side

### 3.1 Admin panel — canonical brand table (`admin/app.py:1271-1338`, verbatim)

This is the single source of truth this spec copies FROM. Light is the default `:root`; dark is
`@media(prefers-color-scheme:dark)` / `body[data-theme=dark]` (identical values, kept in two selectors so a
manual theme toggle works without JS re-evaluating the media query).

| Token | Light | Dark |
|---|---|---|
| `--bg` | `#f4f7f6` | `#0a0c12` |
| `--fg` | `#16201b` | `#e7ebf3` |
| `--muted` | `#566b63` | `#aab2c5` |
| `--border` | `#dde7e2` | `#262c3d` |
| `--panel` | `#ffffff` | `#141826` |
| `--card1` | `#ffffff` | `#181d2b` |
| `--card2` | `#f2f8f5` | `#0e1320` |
| `--pre-bg` / `--pre-fg` | `#0e1320` / `#d4dbe8` | `#070a10` / `#d4dbe8` |
| `--link` / `--brand` | `#0c8466` | `#5fe0bb` |
| `--accent` | `#0f9b76` | `#40c8a0` |
| `--accent2` | `#13b487` | `#5fe0bb` |
| `--teal` | `#0f9b76` | `#40c8a0` |
| `--pink` | `#d6498f` | `#ec6ead` |
| `--amber` | `#b9791a` | `#f5b945` |
| `--btn-bg` / `--btn-hover` / `--btn-fg` | `#e6efeb` / `#d8e7e1` / `#214036` | `#1b2230` / `#252d3d` / `#d7deea` |
| `--btn-primary` / `-hover` / `-fg` | `#40c8a0` / `#2c8e72` / `#04130e` | `#40c8a0` / `#5fe0bb` / `#04130e` |
| `--danger` / `-hover` | `#d23b54` / `#b32942` | `#e0556b` / `#f3667c` |
| `--ok-bg` / `-fg` / `-border` | `#e4f7ef` / `#0a6b4d` / `#a9e3cf` | `#0f2a22` / `#7ff0c8` / `#1f5a47` |
| `--warn-bg` / `-fg` / `-border` | `#fff4d6` / `#7a5200` / `#e6cf8f` | `#2c2410` / `#ffd58a` / `#6b5520` |
| `--err-bg` / `-fg` / `-border` | `#fde8ee` / `#9a1b3a` / `#f0b9c7` | `#2a1622` / `#ffb3c4` / `#5b2740` |
| `--dot-up` / `--dot-down` | `#1faf6b` / `#d23b54` | `#42d392` / `#ff5c7c` |
| `--grad` | `linear-gradient(100deg,#0c8466,#0f9b76 45%,#13b487)` | `linear-gradient(100deg,#2c8e72,#40c8a0 45%,#5fe0bb)` |

### 3.2 Landing page — current tokens (`scripts/landing/index.html.tmpl:31-34`)

```css
--bg:#0a0d1e; --card:#141936; --card2:#10142e; --ink:#eef1ff; --mut:#9aa3c4;
--blue:#5f8cff; --indigo:#8a7cff; --pink:#ec6ead; --teal:#40c8a0;
```

...plus hardcoded (non-variable) hex used directly in the aurora orbs (`:34-48`), the `h1` gradient
(`:65-67`), the `.badge` gradient (`:56-59`), `theme-color` (`:29`), and the `.authbar .btn` gradient
(`:118-119`). Two tokens are **already** brand-exact matches to admin's dark palette: `--pink:#ec6ead` and
`--teal:#40c8a0`. Everything driving the page's dominant hero look — the orbs, the `h1` gradient, the badge,
the `.btn` gradient, `theme-color` — is still blue/indigo/purple and has never been touched to match.

## 4. Architecture decisions

### AD-1 — every new landing hex value is pulled from admin's DARK palette, not freshly designed

The landing page is a fixed-dark aesthetic (no light mode, §2), so §3.1's **dark** column is the only
column relevant here. Rather than inventing new "teal-ish" colors, every replacement hue in §5 is one of
admin's existing dark tokens verbatim — including reusing `--ok-fg:#7ff0c8` (a bright mint highlight
already in the admin palette) for the `h1` gradient's midpoint. This keeps the two files provably
consistent (a diff between "landing hex" and "admin hex" is either `0` or a deliberate, documented
exception) rather than "close enough by eye."

### AD-2 — duplication contract: two standalone files, kept in sync by convention, not a build step

Per the task brief, the files stay standalone by design (landing has no Python/Flask dependency; admin has
no template-render step). The contract: **if you change a brand color in one file, change it in the
other** — enforced today only by this spec's §5 mapping table and a comment in both files pointing at each
other. A future single source (not built now) could be a small `scripts/lib/brand-tokens.env` (`KEY=hex`
pairs) that (a) `84-install-landing.sh`/`regen-landing.sh` `sed`-substitute into the template the way
`${DOMAIN}` already is, and (b) a one-line Python loader turns into the `CSS` string's `:root` block in
`admin/app.py`. Noting it as future work only — implementing a token-loader for `admin/app.py`'s CSS is a
larger, riskier change to a security-sensitive file than this milestone should bundle.

### AD-3 — `regen-landing.sh` renders the page ONLY; it must NEVER touch Caddy

`regen-landing.sh` is called from the Sites deploy/delete hot path (§9). SPEC-SITES-PIPELINE AD-1 requires
per-deploy operations to be pure filesystem ops ("deploy/rollback/delete = directory + symlink operations
only... nothing to corrupt per deploy"). If `regen-landing.sh` also re-rendered `/etc/caddy/apps/
landing.caddy` and ran `caddy validate` on every deploy, it would reintroduce exactly the per-deploy Caddy
risk AD-1 was designed to eliminate — for a vhost that never actually needs to change per deploy (only the
page content does). `regen-landing.sh` therefore does **only** steps 1-2 of the current
`84-install-landing.sh` (build cards, render, write `index.html`); the vhost render + `caddy validate` stay
in `84-install-landing.sh`, install-time only (§8).

### AD-4 — the "your sites" registry read is a `python3 -c` one-liner, safe by construction

Site names are already `SUB_RE`-validated at deploy time (SPEC-SITES-PIPELINE §7: `^[a-z0-9]([a-z0-9-]{0,
61}[a-z0-9])?$`) — no whitespace, no shell metacharacters, no newlines can ever be in the registry's `sites`
keys. That means the bash side of `regen-landing.sh` can safely newline-split the Python script's stdout
without further escaping (unlike arbitrary JSON string content, which this deliberately never touches —
the Python one-liner emits ONLY validated names, one per line, nothing else from the registry).

### AD-5 — `regen-landing.sh` gets a `--print` flag as the laptop-testability seam

Steps 1-2 (build cards, render via `awk`) are pure bash/awk/python3 — no proot dependency. Only the final
write (`proot-distro login debian -- ... cat > .../index.html`) needs a real Termux userland, because
Caddy — and thus `LANDING_ROOT` — lives inside it. `--print` stops right after rendering and writes the
HTML to stdout instead of calling `proot-distro`, so the render logic is exercisable on a laptop with zero
Termux/Android dependency (§10).

### AD-6 — `84-install-landing.sh` becomes a thin wrapper: delegate the render, keep the install-only parts

Extracting steps 1-2 out of `84-install-landing.sh` and into `regen-landing.sh` removes ~75 lines of
card-building/`awk`-substitution logic from the install script, leaving it with exactly the parts that
genuinely only make sense at install time: favicon copy, vhost render + `sed` substitution, `caddy
validate`. One render code path, used by both the installer and the Sites hot path — no forked logic to
keep in sync (§8).

### AD-7 — call-site error policy differs on purpose: fail-closed at install, best-effort at deploy

`regen-landing.sh` itself always exits nonzero on a genuine error (template missing, render came out
empty) — it does not soften its own exit code. The two callers apply **different** policies to that exit
code, deliberately:

- `84-install-landing.sh` calls it **without** `|| true` → a broken landing render fails the install
  (fail-closed, matches the script's existing `caddy validate ... || die` convention).
- `site-deploy.sh` / `site-delete.sh` (M1, not yet written) call it **with** `|| true`, per SPEC-SITES-
  PIPELINE §6's own framing ("landing-regen hook") → a landing-page hiccup must never fail a site deploy;
  the site itself deploying successfully is the thing that actually matters on that path.

### AD-8 — sites cards are visually distinct from app cards, and the "live" dot is honestly decorative

The landing page has no JS backend and is rendered at deploy time, not live-polled — so a per-card "site is
up" indicator would be a lie the moment the page goes stale between deploys. The sites card design (§6)
gets a small dot next to the site name purely as a visual "this is a deployed site, not an app" marker, and
the spec is explicit in the card's own doc comment that it is NOT a live health check (that lives in
SPEC-SITES-PANEL §14, inside the authenticated admin panel, where a genuine per-request probe is
affordable).

## 5. Token remap table

| Element | Old (purple/blue) | New (teal, from §3.1 dark) | Source token |
|---|---|---|---|
| `theme-color` meta (`:29`) | `#8a4dff` | `#40c8a0` | `--accent`/`--teal` |
| `--bg` | `#0a0d1e` | `#0a0c12` | `--bg` |
| `--card` | `#141936` | `#181d2b` | `--card1` |
| `--card2` | `#10142e` | `#0e1320` | `--card2` |
| `--ink` | `#eef1ff` | `#e7ebf3` | `--fg` |
| `--mut` | `#9aa3c4` | `#aab2c5` | `--muted` |
| `--blue` (retired) | `#5f8cff` | *(removed — see below)* | — |
| `--indigo` (retired) | `#8a7cff` | *(removed — see below)* | — |
| `--pink` | `#ec6ead` | `#ec6ead` *(unchanged — already exact)* | `--pink` |
| `--teal` | `#40c8a0` | `#40c8a0` *(unchanged — already exact)* | `--accent`/`--teal` |
| NEW `--mint` | — | `#5fe0bb` | `--accent2` |
| NEW `--amber` | — | `#f5b945` | `--amber` |
| Orb `o1` | `#1f4fff` | `#40c8a0` | `--accent`/`--teal` |
| Orb `o2` | `#7a4dff` | `#5fe0bb` | `--accent2`/new `--mint` |
| Orb `o3` | `#e6559b` | `#ec6ead` | `--pink` (snap to exact) |
| Orb `o4` | `#1fb6a8` | `#f5b945` | `--amber` (was a near-duplicate of `--teal` — now a genuinely distinct 4th hue) |
| `h1` gradient | `#9cc0ff,#c4b6ff 35%,#ffb3d9 65%,#9cc0ff` | `#7ff0c8,#5fe0bb 35%,#ec6ead 65%,#7ff0c8` | `--ok-fg`, `--accent2`, `--pink` |
| `.badge` gradient | `rgba(95,140,255,.35),rgba(236,110,173,.35)` | `rgba(64,200,160,.35),rgba(236,110,173,.35)` | `--accent`, `--pink` |
| `.btn` gradient | `rgba(95,140,255,.24),rgba(138,124,255,.16)` | `rgba(64,200,160,.24),rgba(95,224,187,.16)` | `--accent`, `--accent2` |
| `.btn` box-shadow | `rgba(95,90,255,.28)` / hover `.42` | `rgba(64,200,160,.30)` / hover `.45` | `--accent` |
| `.who .dot` | `var(--teal)` | *(unchanged — was already correct)* | — |
| `.m` accent class | `var(--blue)` | `var(--teal)` | `--accent` |
| `.w` accent class | `var(--indigo)` | `var(--mint)` | `--accent2` |
| `.l` accent class | `var(--pink)` | `var(--pink)` *(unchanged)* | `--pink` |
| `.p` accent class | `var(--teal)` | `var(--amber)` | `--amber` (frees `--teal` for `.m`, removes the old `.p`/`--teal` redundancy) |
| `.adm` accent class | `#f5b945` | *(now identical to `.p` — retire `.adm`, use `.p`; minor cleanup, not required)* | — |

## 6. `index.html.tmpl` diff-level changes

- `:root` block (`:31-34`): replace with the six kept/renamed vars from §5's table (`--bg --card --card2
  --ink --mut --teal --mint --pink --amber`; `--blue`/`--indigo` deleted).
- `.aurora .o1..o4` (`:45-48`): four new hex values (§5).
- `h1` (`:63-69`): new gradient stops.
- `.badge` (`:56-60`): new gradient.
- `.btn` (`:115-121`): new gradient + shadow.
- Accent classes `.m/.w/.l/.p/.adm` (`:97-102`): reassigned per §5; `.adm` becomes a dead/redundant alias of
  `.p` (note it in a comment; retiring it outright is a one-line cleanup, not required by this spec).
- `theme-color` meta (`:29`): new hex.
- Header comment block (`:1-20`): document the new `POCKET_SITES_SECTION` marker (below) alongside the
  existing `__BRAND__`/`POCKET_CARDS` documentation.
- **New**: a `POCKET_SITES_SECTION` marker — a single standalone line (same "marker line" convention as
  `POCKET_CARDS`, `:158`), placed immediately after the closing `</div>` of the existing apps `.grid`
  inside `<main>`. `regen-landing.sh` substitutes it with EITHER a fully-formed `<h2 class=subhead>your
  sites</h2><div class="grid">...</div>` block, or an empty string — never a static always-present block —
  so the whole section vanishes cleanly when `ENABLE_SITES` is off or zero sites are deployed (mirroring
  how each app row already conditionally appears/disappears based on its own `ENABLE_*` flag).
- **New CSS** for the sites card variant + the section heading (added near the existing `.card`/`.grid`
  rules, reusing existing vars only):

```css
.subhead{margin:56px auto 0;max-width:760px;text-align:left;color:var(--mut);
  font-size:12px;letter-spacing:3px;text-transform:uppercase;font-weight:700}
.card.site{border-color:rgba(64,200,160,.22)}
.card.site .ic{background:rgba(64,200,160,.18)}
.card.site .ct h3{display:flex;align-items:center;gap:8px}
.card.site .ct h3 .dot{width:7px;height:7px;border-radius:50%;background:var(--teal);
  box-shadow:0 0 8px var(--teal);flex:0 0 auto}
.card.site .ct p{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
```

Per-site card markup emitted by `regen-landing.sh` (§7):

```html
<a class="card site" href="https://blog.example.com" target="_blank" rel="noopener">
  <span class="ic">&#127760;</span>
  <span class="ct"><h3>blog <span class=dot></span></h3><p>blog.example.com</p></span>
  <span class="arr">&#8250;</span>
</a>
```

The `<p>` shows the bare hostname (monospace, distinct from the app cards' prose blurb) rather than a
description — sites don't have operator-authored blurbs the way built-in apps do (AD-8).

## 7. `scripts/landing/regen-landing.sh` — contract

```bash
#!/usr/bin/env bash
# scripts/landing/regen-landing.sh — render-only, callable at RUNTIME (the Sites
# deploy/delete hot path) as well as from steps/84-install-landing.sh at install
# time. See docs/specs/SPEC-LANDING-SYNC.md.
#
# Renders scripts/landing/index.html.tmpl -> ${LANDING_ROOT}/index.html:
#   - one card per ENABLE_<APP>=true flag (unchanged from 84-install-landing.sh)
#   - NEW: a "your sites" card grid read from the Pocket Pages registry, when
#     ENABLE_SITES=true and the registry has at least one entry
#
# Contract:
#   - silent no-op (exit 0) when ENABLE_LANDING != true
#   - NEVER touches Caddy (no vhost render, no `caddy validate`) — see AD-3:
#     SPEC-SITES-PIPELINE AD-1 requires per-deploy operations to be pure
#     filesystem ops, and this script runs on that hot path
#   - idempotent — overwrites LANDING_ROOT/index.html in full every run
#   - --print: write the rendered HTML to stdout instead of the userland, and
#     skip proot-distro entirely — the laptop-testable seam (AD-5)
#   - exits nonzero on a REAL error (template missing, render came out empty);
#     it does NOT soften its own exit code — callers decide fail-closed vs
#     best-effort (AD-7)

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

[ "${ENABLE_LANDING:-false}" = "true" ] || { ok "landing disabled (ENABLE_LANDING != true) — regen no-op"; exit 0; }
require_var DOMAIN "your apex domain"

LANDING_DIR="${POCKET_ROOT}/scripts/landing"
PAGE_TMPL="${LANDING_DIR}/index.html.tmpl"
LANDING_ROOT="/opt/landing"
BRAND="${LANDING_BRAND:-${DOMAIN}}"
# Same PD_BASE pattern as ops/backup-all.sh:33 — plain host-side file I/O to READ
# the registry (only the final WRITE needs proot, because Caddy — and thus
# LANDING_ROOT — lives inside the userland). Laptop-test override: POCKET_SITES_ROOT,
# the SAME seam lib-sites.sh already documents — do NOT invent a second
# registry-specific override; the M1 and M2 test suites must share one fixture
# convention.
PD_BASE="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs"
SITES_ROOT="${POCKET_SITES_ROOT:-${PD_BASE}/debian/var/www/sites}"
SITES_REGISTRY="${SITES_ROOT}/.registry.json"

[ -f "${PAGE_TMPL}" ] || die "landing page template missing: ${PAGE_TMPL}"

# ── 1. App cards — MOVED VERBATIM from 84-install-landing.sh (unchanged logic) ──
ACCENTS=(m w l p); acc_i=0
next_accent() { local a="${ACCENTS[$((acc_i % ${#ACCENTS[@]}))]}"; acc_i=$((acc_i + 1)); printf '%s' "$a"; }
cards=""
emit_card() {  # emit_card <subdomain> <emoji> <title> <blurb>  — unchanged from today
  local sub="$1" emoji="$2" title="$3" blurb="$4" acc href
  acc="$(next_accent)"
  if [ -n "$sub" ]; then href="https://${sub}.${DOMAIN}"; else href="https://${DOMAIN}"; fi
  cards+="      <a class=\"card ${acc}\" href=\"${href}\" target=\"_blank\" rel=\"noopener\">
        <span class=\"ic\">${emoji}</span>
        <span class=\"ct\"><h3>${title}</h3><p>${blurb}</p></span>
        <span class=\"arr\">&#8250;</span>
      </a>
"
}
emit_card "chat" "&#128172;" "Chat" "End-to-end encrypted group chat (Element)."
[ "${ENABLE_LINKDING:-false}" = "true" ] && emit_card "links"  "&#128278;" "Bookmarks"  "Save, tag and organise your links."
# ... every other existing ENABLE_* row from 84-install-landing.sh:92-99, unchanged ...
[ -z "${cards}" ] && cards="      <div class=\"empty\">No apps are enabled yet. ...</div>"

# ── 2. NEW: sites cards, from the registry ──────────────────────────────────
site_cards=""
if [ "${ENABLE_SITES:-false}" = "true" ] && [ -f "${SITES_REGISTRY}" ]; then
  # Names only, one per line: SUB_RE already guarantees no whitespace/metacharacters
  # (AD-4), so plain newline-splitting in bash is safe here.
  while IFS= read -r sname; do
    [ -n "$sname" ] || continue
    site_cards+="      <a class=\"card site\" href=\"https://${sname}.${DOMAIN}\" target=\"_blank\" rel=\"noopener\">
        <span class=\"ic\">&#127760;</span>
        <span class=\"ct\"><h3>${sname} <span class=dot></span></h3><p>${sname}.${DOMAIN}</p></span>
        <span class=\"arr\">&#8250;</span>
      </a>
"
  done < <(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        reg = json.load(f)
except Exception:
    sys.exit(0)          # missing/corrupt registry -> zero site cards, not an error
for name in sorted(reg.get("sites", {})):
    print(name)
' "${SITES_REGISTRY}" 2>/dev/null || true)
fi
sites_section=""
if [ -n "${site_cards}" ]; then
  sites_section="    <h2 class=subhead>your sites</h2>
    <div class=\"grid\">
${site_cards}    </div>
"
fi

# ── 3. Render (awk substitution — same mechanism as today, one more marker) ──
BRAND_HTML="$(printf '%s' "${BRAND}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')"
RENDERED_PAGE="$(
  CARDS_BLOCK="${cards}" SITES_BLOCK="${sites_section}" BRAND_VAL="${BRAND_HTML}" awk '
    {
      line = $0
      gsub(/__BRAND__/, ENVIRON["BRAND_VAL"], line)
      if (line ~ /^[ \t]*POCKET_CARDS[ \t]*$/)         { printf "%s", ENVIRON["CARDS_BLOCK"]; next }
      if (line ~ /^[ \t]*POCKET_SITES_SECTION[ \t]*$/) { printf "%s", ENVIRON["SITES_BLOCK"]; next }
      print line
    }' "${PAGE_TMPL}"
)"
[ -n "${RENDERED_PAGE}" ] || die "rendered landing page came out empty — check ${PAGE_TMPL}"

if [ "${PRINT_ONLY}" -eq 1 ]; then
  printf '%s' "${RENDERED_PAGE}"
  exit 0
fi

# ── 4. Write into the userland (the ONLY proot-dependent step) ─────────────
require_cmd proot-distro
proot-distro login debian -- bash -lc "mkdir -p '${LANDING_ROOT}'" \
  || die "failed to create ${LANDING_ROOT} in the userland"
proot-distro login debian -- bash -lc "umask 022; cat > '${LANDING_ROOT}/index.html'" <<EOF \
  || die "failed to write ${LANDING_ROOT}/index.html"
${RENDERED_PAGE}
EOF
ok "landing page regenerated (${LANDING_ROOT}/index.html; $((acc_i)) app card(s))"
```

> **CORRECTION (2026-07-17, during implementation validation):** the sketch above
> passes `BRAND_VAL="${BRAND_HTML}"` straight into awk's `gsub()`. That is a
> **rendering bug**: in a `gsub()` replacement string, `&` expands to the matched
> text (`__BRAND__`), and the HTML-escaped brand *always* contains `&` after
> escaping (`&amp;`, `&lt;`, …) — so a brand like `A & B` rendered as
> `A __BRAND__amp; B`. The shipped `regen-landing.sh` pre-escapes the replacement
> for gsub in bash before the awk call (`\` → `\\`, then `&` → `\&`):
>
> ```bash
> BRAND_GSUB="${BRAND_HTML//\\/\\\\}"
> BRAND_GSUB="${BRAND_GSUB//&/\\&}"
> …  BRAND_VAL="${BRAND_GSUB}" awk '…'
> ```
>
> `tests/test_landing_regen.py` pins the fix with a `"Bob & Alice <3"` fixture.
> (The bug pre-dates this spec — the same unescaped `gsub` shipped in
> `84-install-landing.sh` since the landing feature landed; extracting the render
> here is what surfaced it.)

## 8. `scripts/steps/84-install-landing.sh` refactor

Steps 1-2 (build cards, render, write `index.html`) are DELETED from this file and replaced with a single
delegating call (AD-6/AD-7 — no `|| true` here, fail-closed at install time):

```bash
say "rendering the landing page via regen-landing.sh"
bash "${POCKET_ROOT}/scripts/landing/regen-landing.sh" \
  || die "landing page render failed — see the output above"
ok "landing page installed (${LANDING_ROOT}/index.html)"
```

Everything install-only stays exactly as it is today, unchanged: the favicon copy (current lines
`149-154`), the vhost `sed` render + write (`165-176`), and the fail-closed `caddy validate` (`178-184`).
`84-install-landing.sh` keeps its own preflight (`require_var DOMAIN`, `require_cmd proot-distro`, the
userland-reachability check) — `regen-landing.sh` re-checks `require_var DOMAIN` itself too since it's also
called standalone from the Sites hot path, where nothing else has already validated the environment.

## 9. Call sites in the SHIPPED M1 pipeline scripts

**`site-deploy.sh` needs NO edit** — the hook already shipped with M1 (commit `c1273c7`), placed after the
registry update and before GC, and it is best-effort by construction:

```bash
# site-deploy.sh (as shipped) — do NOT paste anything over this
REGEN="${POCKET_ROOT}/scripts/landing/regen-landing.sh"
if [ -x "${REGEN}" ]; then
  job_log "${JOB_ID}" "running the landing-regen hook"
  "${REGEN}" || warn "landing-regen hook failed (non-fatal — the deploy itself already succeeded)"
else
  job_log "${JOB_ID}" "landing-regen hook not present yet (no-op until M2 — see SPEC-LANDING-SYNC)"
fi
```

The hook fires the moment `regen-landing.sh` exists — **provided the file is executable**. ⚠ This repo's
convention ships scripts WITHOUT the exec bit (they're invoked via `bash path`); the shipped hook gates on
`[ -x ]` and execs the file directly, so `regen-landing.sh` is the exception: it MUST be committed with the
executable bit set (and a `#!/usr/bin/env bash` shebang), or every deploy silently logs "hook not present
yet" forever. An M2 acceptance test must assert the hook actually fired after a deploy.

**`site-delete.sh` DOES need a small edit** (new-scope flag, see §11): the shipped M1 script has no hook at
all — SPEC-SITES-PIPELINE §6 named the hook only for `site-deploy.sh`. Add the same shipped `REGEN` block
(verbatim from `site-deploy.sh` above, reusing `job_log`/`warn`) right after `registry_remove_site`, so a
deleted site's card leaves the landing page without waiting for the next deploy. This edits an
already-shipped, already-hardened M1 file, and is called out for operator sign-off rather than bundled
silently. Neither script needs to know anything about landing internals beyond "call this script,
best-effort".

`site-gc.sh` deliberately does **NOT** call `regen-landing.sh`: the current card design (§6) shows only
name + URL, neither of which changes when GC prunes old releases — so a GC-triggered regen would be a
no-op write. If a future card design adds release-count/last-updated text (deferred, §2 non-goals), this
decision should be revisited.

## 10. Test plan

**Laptop render test** (no Termux/Android/proot dependency — exercises AD-5's `--print` seam):

```bash
cat > /tmp/fixture.env <<'EOF'
DOMAIN=example.com
ENABLE_LANDING=true
ENABLE_LINKDING=true
ENABLE_SITES=true
LANDING_BRAND=Example
EOF

mkdir -p /tmp/fixture-sites
cat > /tmp/fixture-sites/.registry.json <<'EOF'
{"version": 1, "sites": {
  "blog": {"created": "2026-07-01T00:00:00Z", "updated": "2026-07-17T12:00:00Z",
           "active_release": "20260717T120000Z-a1b2", "releases": ["20260717T120000Z-a1b2"],
           "build": "none", "bytes": 10240, "url": "https://blog.example.com"},
  "docs": {"created": "2026-07-02T00:00:00Z", "updated": "2026-07-16T09:00:00Z",
           "active_release": "20260716T090000Z-c3d4", "releases": ["20260716T090000Z-c3d4"],
           "build": "hugo", "bytes": 51200, "url": "https://docs.example.com"}
}}
EOF

# POCKET_SITES_ROOT = the pipeline's own documented test seam (lib-sites.sh) —
# the registry is always <root>/.registry.json, exactly like production.
POCKET_ENV=/tmp/fixture.env POCKET_SITES_ROOT=/tmp/fixture-sites \
  bash scripts/landing/regen-landing.sh --print > /tmp/rendered.html

grep -q 'class="card site"'     /tmp/rendered.html   # sites section present
grep -q '>blog '                /tmp/rendered.html   # per-site card rendered
grep -q 'blog.example.com'      /tmp/rendered.html
grep -q 'docs.example.com'      /tmp/rendered.html
grep -q 'links.example.com'     /tmp/rendered.html   # unaffected app-card logic still works
grep -qv 'proot-distro'         <(bash scripts/landing/regen-landing.sh --print 2>&1 >/dev/null)  # no proot call in --print mode
```

Because `require_cmd proot-distro` (§7 step 4) sits AFTER the `--print` early-exit, this test path never
needs `proot-distro` to be installed — runnable in CI on a plain Linux runner.

Also assert the negative case: `ENABLE_SITES=false` (or the fixture registry file absent) → `regen-landing.
sh --print` output contains NO `class="card site"` and NO `POCKET_SITES_SECTION`-shaped leftover text.

**E2E assertion** (arm64 qemu, extends M1's harness + SPEC-SITES-PANEL's):

```bash
scripts/sites/site-deploy.sh blog fixture.zip
curl -s -H "Host: ${DOMAIN}" "http://127.0.0.1:${CADDY_PORT}/" | grep -q 'blog.example.com'

scripts/sites/site-delete.sh blog --yes
curl -s -H "Host: ${DOMAIN}" "http://127.0.0.1:${CADDY_PORT}/" | grep -qv 'blog.example.com'
```

Both assertions run WITHOUT a manual `84-install-landing.sh --force` rerun in between — the whole point of
the hot-path hook (§9) is that the landing page tracks deploys/deletes automatically.

**Visual smoke** (manual, once, before shipping): load the re-themed page in a browser next to the admin
panel dashboard side-by-side and confirm they read as one product — not automatable, but worth a line in
the PR description.

## 11. Open questions (for operator/approval before implementation)

- **OQ-1**: This draft lists EVERY deployed site on the (by-default-public, unauthenticated —
  `scripts/landing/landing.caddy.tmpl:22-28`) landing page. An operator may deploy a site not meant to be
  advertised in a public directory (its own auth, if any, is unaffected — this is purely about
  discoverability). Should M2 add an opt-out, e.g. an `"unlisted": false` field in M1's per-site
  `meta.json` (SPEC-SITES-PIPELINE §4) that `regen-landing.sh`'s site-card loop skips when true? This is a
  small schema extension to an ALREADY-APPROVED M1 spec — needs explicit sign-off before either spec is
  amended. Deferring it (ship M2 with "every site is listed, no opt-out") and revisiting later — the same
  pattern M1 itself used for OQ-4/`SITES_SPA_MODE` — is also a legitimate answer.
- **OQ-2**: Is a hard cap on the sites grid needed for an operator with many deployed sites (mirrors the
  admin panel's `files[:30]`-style caps elsewhere)? If so, what should the cutoff be (most-recently-updated
  vs. alphabetical) and what should overflow show (a "+N more — see the admin panel" note-card, or just
  truncate silently)?
- **OQ-3**: Should `.adm`'s retirement (§5, now identical to `.p`) happen in this same change, or as a
  separate later cleanup? Zero functional difference either way — purely a "how big should this diff be"
  call.
- **OQ-4** (new scope, from §9): `site-delete.sh` gets the landing-regen hook block added after
  `registry_remove_site` — a small edit to an already-shipped, already-hardened M1 script whose §6 contract
  did not include the hook. Approving this spec approves that edit. (Without it, a deleted site's card
  lingers on the landing page until the NEXT deploy of any other site regenerates it.)

**Resolutions (2026-07-17, at approval):** OQ-1 — DEFERRED: ship M2 with every site listed, no opt-out
(same defer-and-revisit pattern as M1's OQ-4); the `meta.json` `unlisted` extension stays a candidate for
a later milestone. OQ-2 — no cap in M2; revisit if a real deployment grows a large grid. OQ-3 — retire
`.adm` in this same change (alias `.p`; zero functional difference, keeps the diff honest). OQ-4 —
APPROVED: add the hook block to `site-delete.sh`.
