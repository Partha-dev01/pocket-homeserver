# Media apps — music, books, audiobooks

The **v0.8 "media tier"** adds three optional, self-hosted media servers, plus a
**photo-gallery roadmap note** and an honest **docs-only** note on Jellyfin. All three
are **OFF by default** — enable each with its `ENABLE_<APP>` flag (the
[`setup.sh`](../setup.sh) wizard asks about each):

| App | Hostname | What it is | Install path | Native (non-browser) clients |
|---|---|---|---|---|
| **Navidrome** | `music.${DOMAIN}` | music streaming | pinned static Go binary | Subsonic apps (`/rest/*`) |
| **Kavita** | `books.${DOMAIN}` | manga / comics / ebooks | pinned .NET tarball (+`libicu72`) | OPDS readers (`/api/opds/*`) |
| **Audiobookshelf** | `audiobooks.${DOMAIN}` | audiobooks / podcasts | **built from source** (Node) | mobile apps (`/api/*`, `/feed/*`) |
| ~~Photoview~~ | — | photo gallery | **roadmap** (loopback-bind blocker — see below) | — |
| ~~Jellyfin~~ | — | movies / TV | **docs-only** (see the bottom of this page) | — |

They all follow the [same model as the other optional apps](APPS.md#how-they-all-work-the-common-pattern):
loopback-only backend → core Caddy → Cloudflare Tunnel, a self-contained vhost in
`/etc/caddy/apps/<app>.caddy` validated fail-closed, pinned + sha256-verified
downloads, and the shared crash-respawn supervisor.

Three things are specific to media and worth understanding before you turn one on.

## 1. Storage tier — DB/cache on ext4, the library on the SD

Every media app keeps two very different kinds of data:

- **Its database, search index, and generated cache/thumbnails** — frequent small
  writes that need real `fsync` + atomic rename + POSIX locks. These **MUST** live on
  **ext4** (`$HOME/.pocket/<app>`, bind-mounted into the userland). Each installer
  **refuses `DATA_DIR` (the exFAT SD) fail-closed** — exFAT silently corrupts SQLite
  WAL and thrashes a many-small-files thumbnail cache. This is the same DB-corruption
  class as the [conduwuit post-mortem](RESILIENCE.md).
- **Your bulk media library** (the actual music / books / photos / audiobook files) —
  large and **read-mostly**. This **may** live on the **exFAT SD card** and is
  bind-mounted into the userland. Point each app at it with `NAVIDROME_MUSIC_DIR` /
  `KAVITA_LIBRARY_DIR` / `ABS_LIBRARY_DIR` (default:
  `${DATA_DIR}/<music|books|audiobooks>`).

> proot-distro's `--bind` has **no read-only flag**, so the library bind is read-only
> *by behaviour* (the apps only ever read originals; everything they write goes to the
> ext4 mount), not by mount option. Keep the host library dir non-writable by the
> userland if you want a stronger guarantee.

## 2. Direct-play by default (transcoding is the heavy, opt-in path)

A phone has no usable hardware video/audio transcode path under proot, and software
transcoding pegs the SoC, throttles thermally, and invites the Android Low-Memory
Killer to reap the whole stack. So **every media app here defaults to direct-play**:
the client streams the original file untouched.

- **Navidrome** doesn't even install `ffmpeg` — transcoding is unavailable until you
  add it yourself (opt-in). **Audiobookshelf** installs `ffmpeg` only because it is
  *mandatory for media probing/duration scans*; on-the-fly transcoding stays off.
- **First library scans are heavy regardless of transcoding** — decoding/tagging every
  file, generating thumbnails/covers. Scan a small library first, and prefer scanning
  while the phone is on power and cool. See each app's *Resource & Risk* below.

## 3. Auth — gate the browser UI, EXEMPT the API paths

By default each hostname is gated at the edge by **Cloudflare Access** (you configure
the policy; the repo wires nothing), and each app keeps its own login. But the media
apps have **non-browser clients** (Subsonic players, OPDS readers, the Audiobookshelf
mobile apps) that authenticate with the app's **own token** and **cannot** follow the
interactive Access `302`-to-login. Each vhost therefore reverse-proxies those API
paths **directly, before** the optional Matrix-SSO `forward_auth` gate — and you must
mirror that at the Cloudflare edge with a **path bypass** (or an Access **service
token**) for:

| App | Exempt these paths in Cloudflare Access |
|---|---|
| Navidrome | `/rest/*` (Subsonic API), `/share/*` (anonymous share links) |
| Kavita | `/api/opds/*` (OPDS; the api-key is in the URL) |
| Audiobookshelf | `/api/*`, `/public/*`, `/feed/*`, `/status`, `/healthcheck`, `/ping`, `/hls/*` |

The app's own token/login protects the exempt paths. See [APP_AUTH.md](APP_AUTH.md).

---

## Navidrome — music streaming (`music.${DOMAIN}`)

A self-hosted music server with its own web player and a **Subsonic-compatible API**,
so apps like DSub, Symfonium, play:Sub and Feishin work too. A single static Go binary
(`scripts/apps/navidrome.sh`) supervised on `127.0.0.1:9123`.

- **Bind:** Navidrome **defaults to `0.0.0.0`** — the installer forces `ND_ADDRESS=127.0.0.1`
  and asserts it before launch.
- **Login:** the first visitor creates the admin — do it immediately. Subsonic clients
  use token auth on `/rest/*` (see the auth table above).
- **Data:** SQLite DB + artwork/transcode cache on ext4 (`$HOME/.pocket/navidrome`);
  the music library is read-mostly and may live on the SD.

> **Resource & Risk.** Idle/direct-play streaming is light (~150–400 MB RAM, near-zero
> CPU — it's just file serving). The two heavy events are **(a)** the **first library
> scan** (reads + tags every track; CPU + I/O heavy on a big library — the scan
> schedule is a conservative `@every 24h`, and `0` disables it) and **(b)**
> **transcoding**, which is **off** (no `ffmpeg` installed). Adding transcoding is an
> opt-in heavy path: one MP3-128k transcode ≈ 40% of a core on comparable ARM, so a
> few concurrent transcodes will pin cores and heat the phone. Pin to direct-play.

## Kavita — manga / comics / ebooks (`books.${DOMAIN}`)

A reader/server for comics, manga, and ebooks (CBZ/CBR/EPUB/PDF), with an OPDS feed
for native readers (Panels, Tachiyomi, Chunky). A self-contained .NET build
(`scripts/apps/kavita.sh`) supervised on `127.0.0.1:9124`.

- **Runtime dep:** `libicu72` (the .NET runtime needs system ICU or it won't start) —
  installed automatically. **Never set `DOTNET_RUNNING_IN_CONTAINER`** — it would make
  Kestrel ignore the loopback bind and listen on all interfaces.
- **Bind:** Kavita **defaults to `0.0.0.0,::`**. The installer **pre-seeds**
  `config/appsettings.json` with `IpAddresses=127.0.0.1` **before** first start (so it
  never opens a LAN-exposure window) and asserts it fail-closed. The JWT `TokenKey` is
  generated **off-argv** inside the userland (512-bit) into the `0600` file.
- **Login:** first-run wizard creates the admin; OPDS readers use a per-user api-key in
  the URL (`/api/opds/*` — exempt it, see the auth table).
- **Data:** everything (`kavita.db` + WAL, covers, cache, thumbnails, logs,
  `appsettings.json`) on ext4 (`$HOME/.pocket/kavita`); the library is read-mostly on
  the SD.

> **Resource & Risk.** ~150–300 MB RAM idle (.NET). The heavy path is the **library
> scan**: it unzips CBZ/CBR/EPUB archives and generates a cover thumbnail per
> series/volume/chapter — CPU- and temp-disk-heavy, and the main thermal/LMK risk. An
> LMK kill mid-scan can leave partial state, which is exactly why the DB lives on ext4
> (so it survives). Add libraries in batches; scan while charging. Kavita serves files
> directly (no transcode), which is the light path.

## Photo gallery — on the roadmap (not yet shipped)

A photo gallery was scoped for this tier, with **Photoview** as the candidate. It is
**deferred to the roadmap** because it cannot be bound to loopback safely on this stack,
and loopback-only binding is a non-negotiable security invariant here (every backend
must sit on `127.0.0.1` behind the Caddy → Cloudflare Tunnel edge — proot shares the
host's network namespace, so a `0.0.0.0` bind is a real LAN exposure).

> **Why it's blocked (load-bearing — preserved for a future revisit).** Photoview
> v2.4.0's server calls `http.ListenAndServe(":"+port, …)`, so it binds **`0.0.0.0`
> regardless of `PHOTOVIEW_LISTEN_IP`** (that env var only labels the logged URL). The
> obvious fix — an `LD_PRELOAD` `bind()` shim that rewrites wildcard binds to loopback —
> **does not work for this binary**: Go's `net` listener issues `bind()` as a **raw
> `SYS_BIND` syscall**, never calling the libc `bind` symbol an `LD_PRELOAD` shim hooks
> (this holds even with CGo, and under emulation the raw syscall goes straight through).
> Empirically the binary listened on `*:<port>` **with *and* without** the shim. The
> other userland options for forcing loopback are all unavailable here: **`ptrace`**
> syscall rewriting can't nest (proot is already the tracer), unprivileged **user
> namespaces** are typically disabled on Android, and **seccomp user-notify** bind
> rewriting is complex and can't be validated under proot. A future revisit would need a
> seccomp user-notify bind-rewriter validated on **real hardware**, or upstream adding a
> real listen-address bind.

Everything else about Photoview *did* validate (the daemonless image-extract works, the
arm64 manifest digest and the extracted-binary `sha256` are both known, and the complete
bookworm runtime dep set is worked out) — only the loopback-bind invariant blocks it. If
you want a gallery today and accept the LAN exposure on a trusted private LAN, the
manual escape hatch is the same generic pattern as Jellyfin below.

## Audiobookshelf — audiobooks & podcasts (`audiobooks.${DOMAIN}`)

A server for audiobooks and podcasts with progress sync and good mobile apps. Upstream
ships **no arm64 release binary** (only a multi-arch Docker image), so
`scripts/apps/audiobookshelf.sh` **builds it from source** on-device from a pinned git
tag — exactly like [Pingvin Share](APPS.md#pingvin-share--file-sharing-shareDOMAIN).

> ⚠ **First run is very slow** — a client `npm ci && npm run generate` (a full Nuxt
> build) plus the server's `npm ci` on a phone can take **15–40+ minutes** and is one
> of the heaviest steps in the whole stack. Re-runs skip the build. The build caps the
> V8 heap so it can't OOM-kill the live Matrix/Caddy stack.

- **Bind:** ABS reads `HOST` from the environment with **no default** (unset = `0.0.0.0`),
  so `run.sh` exports **`HOST=127.0.0.1`** and the installer asserts it fail-closed.
- **Native binaries (pinned, no auto-download):** ABS would fetch `ffmpeg` + the
  nunicode SQLite extension from the network on first boot, which defeats pinning. The
  installer pre-places both — apt `ffmpeg`/`ffprobe` (mandatory; ABS exits if their
  paths are unset) and the **sha256-pinned** `libnusqlite3.so` — then sets
  `SKIP_BINARIES_CHECK=1` so nothing reaches out.
- **Login:** the first-run wizard creates the root user. The mobile/desktop apps use a
  JWT bearer to `/api` and other non-browser paths — exempt them at the edge (see the
  auth table).
- **Data:** SQLite DB + config + metadata (covers/cache/backups) on ext4
  (`$HOME/.pocket/audiobookshelf`); the audiobook library is read-mostly on the SD.

> **Resource & Risk.** Idle ~150–300 MB Node RSS; library scans and (especially)
> **on-the-fly transcoding** spike it to 400–700 MB+ and pin the SoC — transcoding is
> the thermal/LMK heavy path and is **not** enabled (prefer client direct-play). The
> **build itself** is the other heavy event (see above). The `sqlite3` native module
> builds via `node-pre-gyp` (a glibc arm64 prebuilt, with `build-essential`+`python3`
> as the fallback compile).

---

## Jellyfin — why it's docs-only (no install script)

Jellyfin (movies/TV, like Plex/Emby) is **deliberately not shipped as an installable
app**. It *can* be made to run, but it is a poor fit for this stack and we'd rather say
so than hand you a footgun:

1. **No usable hardware transcode.** A phone's media engine is exposed via Android
   `MediaCodec`, not the VAAPI/V4L2/Rockchip-MPP paths `jellyfin-ffmpeg` expects under
   proot. So every transcode falls back to **software** (libx264/x265) on the phone
   SoC — real-time 1080p software transcode is marginal-to-impossible, pins all cores,
   throttles thermally, and the Android LMK/OOM reaper will kill the whole proot stack.
2. **Cloudflare Tunnel is the wrong pipe for video.** The free tunnel has request-body
   and buffering constraints (a ~100 MB body cap is a real friction point — see
   [FILES.md](FILES.md)), and Cloudflare's self-serve terms discourage serving a
   disproportionate volume of video through the CDN/tunnel. Streaming a media library
   this way is both technically fragile and ToS-grey.
3. **Footprint.** A self-contained .NET 8 runtime + `jellyfin-ffmpeg` is a heavy RAM
   floor (~250–500 MB idle, spiking to 1 GB+ on a scan) for a phone.

**If you insist anyway** (LAN-only, direct-play, small library), the manual path is the
generic one used by every other app: fetch the **version-pinned arm64 tarball** from
`repo.jellyfin.org` (it ships **no upstream checksum** — `sha256sum` it yourself and
pin it), extract to `/opt` on **ext4**, install `libicu72`/`libfontconfig1`/`libfreetype6`/
`libssl3` + `jellyfin-ffmpeg`, keep `config`/`data`/cache/transcode-temp on ext4 (only
the read-only media library on the SD), set `network.xml`
`LocalNetworkAddresses=127.0.0.1` (but treat the loopback Caddy edge as the *real*
guard — Jellyfin has a history of ignoring that setting), write a Caddy vhost to
`127.0.0.1:8096`, and **disable transcoding / cap concurrent streams**. This repo wires
none of it on purpose.

---

## Enabling, disabling, upgrading

- **Enable:** set `ENABLE_<APP>=true` in `.env` (or via `./setup.sh`), then
  `./scripts/install.sh`. The app installs and its vhost loads on the next edge
  (re)start. Then add the Cloudflare **public hostname** and an **Access policy**
  (with the API-path exemption from the auth table, where applicable).
- **Disable:** set the flag to `false`; remove `/etc/caddy/apps/<app>.caddy` and stop
  its supervisor to take a live one down.
- **Upgrade:** bump the app's pin(s) in [`config/versions.env`](../config/versions.env)
  — for **Audiobookshelf** bump the git tag (and re-derive the nunicode sha if you bump
  it). **Back up `$HOME/.pocket/<app>` first** (the SQLite DBs migrate on first start),
  then re-run the installer.

## See also

- [APPS.md](APPS.md) — the full optional-app catalog + the common install pattern.
- [APP_AUTH.md](APP_AUTH.md) — Cloudflare Access vs the Matrix-SSO gateway; non-browser clients.
- [FILES.md](FILES.md) — the ~100 MB tunnel body cap, ext4-vs-exFAT, "why not Nextcloud".
- [SECURITY.md](SECURITY.md) — the pinning/verification model and threat model.
- [RESILIENCE.md](RESILIENCE.md) — the supervisor, DEGRADED markers, and the DB-on-ext4 rule.
