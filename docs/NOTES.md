# Trilium — notes / wiki (`wiki.${DOMAIN}`)

Trilium Notes (the maintained **TriliumNext** fork) is a hierarchical
notes/personal-wiki app with rich text, code notes, attributes, and full-text
search. It is **optional and OFF by default** — enable it with `ENABLE_TRILIUM=true`.
It lives on `wiki.${DOMAIN}` (the lighter **Memos** app already owns
`notes.${DOMAIN}`; the two are independent and can both be enabled).

## How it installs

`scripts/apps/trilium.sh` downloads the **official first-party arm64 SERVER
tarball** (`TriliumNotes-Server-v<ver>-linux-arm64.tar.xz`, sha256-pinned in
`config/versions.env`). That asset is built in TriliumNext's own CI and **bundles
its own Node runtime + a prebuilt arm64 `better-sqlite3`** — so there is **no
node-gyp / npm compile** on the supported path (this is what makes it feasible on a
phone, where a from-source Node build would be heavy and fragile). The from-source
build path is **explicitly unsupported**.

It is the strongest supply-chain position of the v0.7 apps: a CI-built,
sha256-pinned upstream release asset. It runs via the bundled Node on loopback
`127.0.0.1:9121`; Caddy fronts the edge.

### GLIBCXX boot-smoke (fail-closed)

The bundled `better-sqlite3` is a dynamically-linked native module, so it needs a
new-enough `libstdc++`. The install runs a **one-time boot-smoke** — it loads the
module with the bundled Node and **fails closed with a clear message** if the
userland's `libstdc++`/GLIBCXX is too old. Debian **bookworm** ships a new-enough
`libstdc++` (validated on arm64), so this passes; the check exists so a future
mismatch fails loudly rather than as a silent crash loop.

## Auth model

Trilium's **browser UI** is cookie/session based, so it works behind:

- its **own password login** (the default — `TRILIUM_NOAUTH=false`, you set the
  password on first visit), and/or
- the **Cloudflare Access** edge policy, and/or
- the optional **Matrix-SSO `forward_auth` gateway** (a commented block in the
  vhost). If — and only if — you front it with the gateway and have confirmed the
  loopback bind holds, you may set `TRILIUM_NOAUTH=true` so the gate is the sole
  auth.

> `noAuthentication=true` is a **footgun** if the loopback bind or the gate ever
> fails open — then the instance is unauthenticated. We **default it OFF**; enable
> it only behind a confirmed gate.

**ETAPI (the REST API) + the desktop/mobile SYNC client** are native-token clients
that **cannot** follow a 302 — for those, keep native auth ON and add a **CF Access
service-token exemption** for `wiki.${DOMAIN}` (operator-side; see
[APP_AUTH.md](APP_AUTH.md)).

### Loopback bind (load-bearing)

Trilium **defaults to `0.0.0.0`** (confirmed in its source). The launcher forces
`TRILIUM_NETWORK_HOST=127.0.0.1` and the install **asserts** it fail-closed —
otherwise the instance would be LAN-exposed. `TRILIUM_NETWORK_TRUSTEDREVERSEPROXY=true`
lets Trilium read `X-Forwarded-*` from the loopback Caddy.

## Storage (document.db on ext4 — load-bearing)

`document.db` (+ WAL/SHM) and the whole data dir live on **ext4** at
`$HOME/.pocket/trilium` (bind-mounted to `/opt/trilium/data`), never on exFAT —
`better-sqlite3` + WAL need real `fsync`, atomic rename, and locks. Attachments are
stored **inside** the data dir/DB (there is no external blob tier), so plan for the
DB to grow on ext4.

## Upgrades

**Back up `document.db` first** — Trilium auto-migrates the DB/sync schema on first
start and that is **one-way**. Bump `TRILIUM_VERSION` + `TRILIUM_SHA256` together in
`config/versions.env` (get the digest from the GitHub release) and re-run
`scripts/install.sh --force`. If you use the desktop/mobile sync client, any sync
peer must be upgraded in lockstep.

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM (idle)** | ~120–220 MB (a persistent Node/Express + better-sqlite3 process) — heavier than the Go/PHP apps; upstream's stated minimum is 256 MB. |
| **RAM (peak)** | ⚠️ **300–600 MB+** during the built-in **OCR** (image/PDF/Office text extraction) and spreadsheet note types, large imports, or FTS reindex. These are **heavy on-demand** ops — use them sparingly on a phone. |
| **CPU / LMK / thermal** | Idle is benign. OCR / big import / reindex are the LMK + thermal hotspots; the supervisor backoff + WAL recover a kill cleanly. |
| **Storage** | ~250–350 MB installed (bundled Node + node_modules). `document.db` grows with notes/attachments (no SD offload). |
| **Supply chain** | Strong: official CI-built, sha256-pinned first-party arm64 asset (no node-gyp). Source build is unsupported. |
| **On-device risk** | The GLIBCXX boot-smoke is the single most likely failure point; bookworm passes it. |
| **Auth boundary** | Browser UI = the login gate is fine; **ETAPI + sync client need a service-token exemption**. |
| **CF tunnel ~100 MB cap** | Bulk note/attachment imports can exceed it — do large imports on loopback/LAN. |

## Enabling

```ini
# .env
ENABLE_TRILIUM=true
# Optional: set true ONLY when fronting Trilium with the Matrix-SSO gateway.
TRILIUM_NOAUTH=false
```

Then `./pocket.sh` → Install, add the `wiki.${DOMAIN}` public hostname (and an
Access policy) in the Cloudflare dashboard, and visit it to set your password. To
disable: set `ENABLE_TRILIUM=false` and stop the service.

## See also

- [APP_AUTH.md](APP_AUTH.md) — the login-gate vs service-token distinction.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model + the ~100 MB body cap.
- [BACKUPS.md](BACKUPS.md) — back up `document.db` before every upgrade.
- [UPDATING.md](UPDATING.md) — version pins.
