# Files & Sync (personal cloud)

Three optional, default-off modules let the phone serve and sync your own bulk
files: **Dufs** (a browser UI plus a WebDAV mount on `files.${DOMAIN}`),
**FileBrowser** (multi-user accounts and share links, also on `files.${DOMAIN}`,
mutually exclusive with Dufs), and **Syncthing** (peer-to-peer folder sync, no
public hostname at all). This is the tier-3 "personal cloud" slice — not a
collaboration suite or a Dropbox clone, just single-purpose tools to move your own
content on and off the device. Everything here is gated behind an `ENABLE_*` flag,
is **off by default**, binds loopback only, and keeps its secrets in a 0600 file or
in Syncthing's own config — never in `.env`.

## Why not Nextcloud, and why no SMB

This tier deliberately omits the two things people ask for first. The reasons are
concrete, not ideological.

**Nextcloud is the wrong shape for a 4 GB phone.** A real Nextcloud is a PHP-FPM
pool plus a database plus background cron plus its app store — a stack whose RAM,
CPU, and thermal appetite collides head-on with a phone that is already running
Matrix and the rest of this stack. The Docker AIO image, snap, and NextcloudPi all
assume an environment we do not have inside unprivileged proot-Debian, so the only
even-feasible path was the manual PHP + SQLite install — and that path still carries
the low-memory-killer / DB-corruption risk this whole project spends its effort
avoiding (see [RESILIENCE.md](RESILIENCE.md)). Run Nextcloud on real hardware where
it belongs; on the phone, use these single-purpose modules instead.

**SMB/CIFS does not fit the model.** SMB is a LAN file-sharing protocol with no
clean story over CGNAT and an HTTP-oriented Cloudflare Tunnel — the tunnel forwards
HTTP(S), not SMB. It is also awkward under unprivileged proot: the standard port
445 is privileged and blocked, so the best you could do is a high-port, LAN-only
listener, which Windows' built-in client cannot even connect to (it insists on
445). That breaks both norms this project holds: "reach it anywhere through the
tunnel" and "bind loopback only." If you want network-drive semantics over the
tunnel, use **Dufs' WebDAV mount** (below) — it gives you a mapped drive in Finder
or Windows Explorer through the same tunnel and Access policy as everything else.
If you genuinely only need LAN bulk sharing, run a separate share off the SD card
outside this project; it is not something pocket-homeserver tries to own.

## Choosing: Dufs vs FileBrowser (mutually exclusive on `files.${DOMAIN}`)

Both serve files from a browser on the **same hostname**, so you pick exactly one.
Enabling both is a configuration error and the installer **dies fail-closed** rather
than letting two apps fight over `files.${DOMAIN}`.

| | **Dufs** (recommended default) | **FileBrowser** (classic v2) |
|---|---|---|
| Binary | single static Rust binary, ~10–20 MB | Go binary, ~20–40 MB |
| State | **none** — no database | a **BoltDB** file (pinned to ext4) |
| Access model | flat; one served root | real **multi-user accounts**, per-user scopes |
| Sharing | — | **share links** (time/path-scoped) |
| WebDAV | **yes** — mount in Finder / map a Windows drive / DAVx5 | **no** — browser only |
| Preview | basic in-browser | in-browser preview + edit |
| Inner auth | light HTTP **Basic** auth (hashed creds) | account login (admin seeded on first run) |
| Default writes | **read-only** (uploads/deletes off until you opt in) | per-user permission |

Use **Dufs** when you want a near-zero-overhead way to browse your files and mount
them as a network drive, and you are fine with a single shared view behind the edge
gate. It is the recommended default precisely because it has no database, no
accounts to manage, and is read-only until you explicitly turn writes on.

Use **FileBrowser** when you need *several* people with separate logins, per-user
folders, or shareable links — at the cost of a small BoltDB to back up and no
WebDAV mount. FileBrowser is in upstream maintenance-only mode (stable, no new
features), which is fine for this use.

## Syncthing — the large-data path

Syncthing is **pure peer-to-peer** folder sync. It never touches Caddy and never
goes through the Cloudflare Tunnel, which is exactly why it is the right tool for
moving large data on and off the phone: the tunnel's ~100 MB body cap (next
section) simply does not apply to it. Syncthing talks directly to your other
devices (laptop, desktop, NAS), falling back to volunteer relay servers only when
a direct connection can't be made.

- **No public hostname, no edge auth.** There is nothing to expose through the
  tunnel and no Cloudflare Access policy to attach. The **web GUI stays loopback
  only** (`127.0.0.1:8384`); reach it over an SSH tunnel:
  `ssh -L 8384:127.0.0.1:8384 <phone>` then open `http://127.0.0.1:8384`.
- **Pairing is by device ID.** Each device's ID is the SHA-256 of its TLS
  certificate, so a connection requires both sides to have explicitly added the
  other's ID. There is no separate username/password to authenticate a peer — the
  cert *is* the identity, and content is always encrypted in transit.
- **The index DB lives on ext4.** Syncthing's config, certificate, and SQLite
  index database go in its `HOME` under the userland / `$HOME/.pocket`. **Synced
  folders should also default to ext4.** The exFAT SD card is **warned and
  unsupported** as a sync target: exFAT/FUSE cannot rename-over-existing, which is
  how Syncthing finalizes a file, so syncing onto the SD card can stall or corrupt
  (see *Storage layout*).
- **Doze can pause it.** Android's Doze will suspend the process when the screen is
  off; hold a wake-lock via Termux:Boot (see [SETUP.md](SETUP.md)) if you need sync
  to keep running in the background.
- **No inotify under proot → periodic rescan.** Filesystem watching does not work
  reliably inside proot, so Syncthing falls back to periodic rescans. That trades
  latency (changes are noticed on the next scan, not instantly) against battery
  (more frequent scans cost more power). Tune the rescan interval per folder to
  taste.

## The Cloudflare Tunnel ~100 MB body cap (load-bearing)

On Cloudflare's **free plan, proxied requests cap the request body at ~100 MB.**
This is the single biggest constraint of the *web* file apps, so be explicit about
it:

- **Downloads are unaffected** — responses are not capped this way; pulling large
  files down through the tunnel works.
- **Uploads over ~100 MB through the tunnel FAIL** for the Dufs browser UI and for
  FileBrowser, because both upload a file as a single POST/PUT request and the body
  exceeds the edge limit. The request is rejected at Cloudflare before it reaches
  the phone.

Workarounds, in order of preference:

1. **Dufs chunked WebDAV.** A chunk-aware client (e.g. `rclone`) can upload via
   WebDAV `PATCH` / partial `PUT` with each chunk kept under 100 MB, so no single
   request trips the cap. This requires a **Cloudflare Access service-token
   exemption** on the hostname (a WebDAV client cannot do the interactive Access
   login — see the next section).
2. **Syncthing for big media** — it is off-tunnel, so the cap is irrelevant.
3. **A LAN session** — copy directly over the local network when both devices are
   on the same Wi-Fi.

If your workflow is mostly *large* uploads, Syncthing is the right answer; the web
apps are best for browsing and modest transfers.

## WebDAV + non-browser clients (auth)

A WebDAV client (Finder, Windows map-drive, `rclone`, davfs2, DAVx5) **cannot follow
the Cloudflare-Access / Matrix-SSO 302-redirect to a login page** — it just sees a
redirect to HTML and fails. To mount Dufs over the tunnel you therefore use a
service-token instead of an interactive login:

1. In the **Cloudflare dashboard** (operator-side — the repo wires nothing here),
   attach a **Cloudflare Access service-token** policy to `files.${DOMAIN}`.
2. Have the client send the token in headers on every request:
   `CF-Access-Client-Id` and `CF-Access-Client-Secret`
   (`rclone --header "CF-Access-Client-Id: …"` / the equivalent davfs2 config).

This is why the WebDAV path is **Dufs-only with Cloudflare Access**: the optional
**Matrix-SSO gateway has no service-token path** and cannot authenticate a WebDAV
client. See [APP_AUTH.md](APP_AUTH.md) for the difference between the two edge
gates.

**Dufs' own Basic auth is the inner gate.** Behind the edge, Dufs still requires an
HTTP login of its own (defense in depth). Use **Basic** auth with **hashed**
credentials, not Digest — TLS terminates at the Cloudflare edge and the origin hop
is loopback only, so Basic-over-loopback does not expose the password on the wire,
and Digest interoperates poorly with several clients. See [SECURITY.md](SECURITY.md)
for the trust-boundary picture.

## Storage layout (ext4 vs exFAT SD)

The same split this project uses everywhere applies here: **state on ext4, bulk
content on the SD card.**

| Lives on **ext4** (userland / `$HOME/.pocket`) | Lives on **exFAT SD** (`${DATA_DIR}`) |
|---|---|
| Dufs 0600 config YAML + hashed credentials | the bulk files Dufs *serves* (read-only is safe) |
| FileBrowser **BoltDB** | the bulk files FileBrowser *serves* |
| Syncthing `HOME`: config + TLS cert + **SQLite index DB** | (synced content **should stay on ext4** — see below) |

exFAT/FUSE hazards apply only **when writes are turned on**:

- **No atomic rename-over-existing** — breaks resumable uploads and the
  "write temp, rename into place" finalize step that Dufs, FileBrowser, and
  Syncthing all rely on.
- **No `fsync`** — no durability guarantee on the removable card.
- **No `:` in filenames** — breaks some WebDAV and macOS clients that use `:`.
- **No unix permissions** — a 0600 secret cannot be enforced there, which is why
  every secret stays on ext4.

So: **read-only SD serving is safe** (Dufs default), **writable SD serving is
risky**, and **Syncthing-onto-exFAT may stall or corrupt** — keep synced folders on
ext4.

## The Quantum fork note

[`gtsteffaniak/filebrowser`](https://github.com/gtsteffaniak/filebrowser) ("FileBrowser
Quantum") is a heavier fork that adds the things classic FileBrowser lacks — OIDC /
LDAP / 2FA single sign-on and a fast in-app search. It earns that by **pre-indexing
the whole tree into memory**, and upstream's own figures put a typical install at
**100 MB–500 MB RAM**, climbing into gigabytes for large or deep trees. On a 4 GB
phone already running Matrix that is a real **low-memory-killer / thermal risk**, so
Quantum is **documented as an opt-in only and is not shipped** by these modules.
(Note also that WebDAV in Quantum is recent/partial; for a dependable WebDAV mount,
Dufs remains the recommendation.)

## Enabling

Pick the modules with `./setup.sh` (or set the flags directly in `.env`) and re-run
the installer:

| Flag | Module | Loopback port | Public hostname |
|---|---|---|---|
| `ENABLE_DUFS` | Dufs | `9117` | `files.${DOMAIN}` |
| `ENABLE_FILEBROWSER` | FileBrowser | `9118` | `files.${DOMAIN}` |
| `ENABLE_SYNCTHING` | Syncthing GUI | `8384` (loopback only) | — (none) |

`ENABLE_DUFS` and `ENABLE_FILEBROWSER` are **mutually exclusive** (both claim
`files.${DOMAIN}`); enabling both fails the install.

For the **file apps**, do the two manual Cloudflare steps (same as every app — see
[APP_AUTH.md](APP_AUTH.md)):

1. **Public Hostname:** Tunnels → your tunnel → *Public Hostnames* → *Add* —
   `files.${DOMAIN}` → service `http://localhost:${CADDY_PORT}`.
2. **Access policy:** Access → *Applications* → *Add* (self-hosted) on
   `files.${DOMAIN}`, with an Allow policy (your trusted emails / OTP / IdP). For
   WebDAV, add the **service-token** policy described above.

**Syncthing needs no public hostname and no Access policy** — it is off-tunnel; you
only reach its GUI over the SSH tunnel.

## Resource & Risk

- **Footprint is small relative to the rest of the stack.** Dufs idles around
  ~5–15 MB; FileBrowser ~20–40 MB plus a KB–MB BoltDB; Syncthing ~50–150 MB idle
  and spiky during SHA-256 hashing and rescans. All three are **low LMK risk**
  compared to Matrix or the LLM bots — but Syncthing's hashing bursts are the one to
  watch on a constrained phone.
- **The ~100 MB tunnel cap is the dominant limitation** of the web apps (uploads
  over ~100 MB through the tunnel fail). Use chunked WebDAV, Syncthing, or LAN.
- **Dufs defaults to `0.0.0.0`.** The install **forces and asserts the bind to
  loopback** so it is never reachable on the LAN — this is a security-load-bearing
  assertion (the operator should verify the listen address after install).
- **exFAT write hazards.** Read-only SD serving is safe; turning on writes to the SD
  card (or syncing onto it) risks stalls/corruption from no atomic rename and no
  `fsync`. Keep writable data and the index DBs on ext4.
- **Syncthing leaks connection metadata.** Global discovery and relays expose your
  **device ID, public IP, and the connection graph** to Syncthing's discovery/relay
  network — file **contents stay encrypted** and relays cannot read them, but the
  metadata is visible. Disable global discovery / use only static device addresses
  if that matters to you.
- **The WebDAV open-server foot-gun.** If you attach a service-token (or remove the
  Access policy) to make WebDAV work, **Dufs' own Basic auth becomes the only gate**
  — do not disable it, or you publish an open writable file server.
- **FileBrowser seeds a deterministic admin on first run.** On a fresh database it
  creates the admin from your `.env` `ADMIN_USER` / `ADMIN_PASSWORD` (passed
  off-argv as a pre-hashed bcrypt import, never on the process command line), so
  there is no "random password printed once to the log" lockout trap — log in with
  your `.env` admin password and change it. Re-running the installer never resets a
  password you have changed (the seed is gated on a fresh DB).
- **Live behaviour is operator-verified.** The on-device WebDAV mount, FileBrowser's
  RAM under a large directory listing, and Syncthing's reboot survival + sync +
  inotify-fallback behaviour can only be fully exercised on the running phone — the
  install validates config fail-closed, but the runtime characteristics are yours to
  confirm.

## See also

- [APP_AUTH.md](APP_AUTH.md) — Cloudflare Access vs the Matrix-SSO gateway (and why
  WebDAV needs a service token).
- [SECURITY.md](SECURITY.md) — trust boundaries and the loopback-only norm.
- [RESILIENCE.md](RESILIENCE.md) — the LMK / DB-corruption failure modes this tier
  is shaped around.
- [BACKUPS.md](BACKUPS.md) — note that FileBrowser's BoltDB is inside the userland
  and is captured by the rootfs backup; the bulk content on `${DATA_DIR}` is covered
  by copying the data volume.
