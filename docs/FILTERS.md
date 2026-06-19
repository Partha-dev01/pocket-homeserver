# Privacy & media filters (optional)

Two small, independent loopback proxies that sit in front of the Matrix
homeserver on a few specific routes. Both are **off by default**, run
**Termux-native** (not inside the proot userland), and bind **loopback only** —
Caddy is the only thing that ever reaches them.

| Filter        | Flag                 | Port (default)            | Job                                                            |
|---------------|----------------------|---------------------------|---------------------------------------------------------------|
| user-filter   | `ENABLE_USER_FILTER` | `USER_FILTER_PORT` (8449) | Hide chosen accounts from the member/user-directory search.   |
| media-filter  | `ENABLE_MEDIA_FILTER`| `MEDIA_FILTER_PORT` (8450)| Fix missing `Content-Type` on media so mobile clients render. |

Enable either (or both) in `.env`, then run the installer / `./pocket.sh`. The
install step `scripts/steps/78-install-filters.sh` self-gates: it runs if either
flag is `true` and supervises only the enabled filter(s).

Both proxies forward to the homeserver loopback listener, read from
`MATRIX_LOOPBACK` (default `http://127.0.0.1:8448` — matches the core Caddyfile
`/_matrix` route). Logs land in `${POCKET_LOG_DIR}/{user,media}-filter.log`.

---

## user-filter — hide accounts from member search

A Flask proxy on `127.0.0.1:${USER_FILTER_PORT}`. Caddy routes **only** the
Matrix user-directory search endpoint through it:

```
Caddy → 127.0.0.1:8449 (user-filter) → 127.0.0.1:8448 (homeserver)
```

It forwards the search request, parses the JSON response, drops any MXID listed
in the private-users file from `results`, and returns the rest. Every other
`/_matrix` path bypasses it entirely (Caddy routes those straight to the
homeserver).

It **fails open**: any forwarding or parse error returns the upstream response
unchanged. A bug here can only fail to hide an account — it can never break or
deny member search.

### The private-users list

`${DATA_DIR}/secrets/private-users.txt` (seeded `0600` on install). One MXID per
line; `#` and blank lines ignored. **Re-read on every request** — edit it live,
no restart needed:

```
# private-users
@alice:example.com
@ops:example.com
```

Override the path with `PRIVATE_USERS_FILE` if you keep it elsewhere.

---

## media-filter — fix missing Content-Type

A stdlib-only proxy on `127.0.0.1:${MEDIA_FILTER_PORT}`. Caddy routes **only**
the media download / thumbnail / preview_url routes through it:

```
Caddy → 127.0.0.1:8450 (media-filter) → 127.0.0.1:8448 (homeserver)
```

Some homeserver builds leave `Content-Type` empty on og:image fetches and some
downloads. Browsers sniff and render fine; some native mobile clients don't and
fail to show the thumbnail. The proxy peeks the first bytes, sets a
`Content-Type` from a magic-bytes lookup (JPEG/PNG/WEBP/GIF/AVIF/HEIC/MP4/SVG/
PDF/BMP) when upstream omits it, and streams the body through unchanged. The
caller's `Authorization` header is passed through verbatim.

Routes intercepted (everything else 404s):

```
GET /_matrix/media/v3/download/<server>/<id>[/<filename>]
GET /_matrix/media/v3/thumbnail/<server>/<id>
GET /_matrix/client/v1/media/download/<server>/<id>[/<filename>]
GET /_matrix/client/v1/media/thumbnail/<server>/<id>
GET /_matrix/media/v3/preview_url
GET /_matrix/client/v1/media/preview_url
```

---

## Caddy routing (automatic)

These filters intercept routes on the **existing** chat/Matrix vhost — they do
**not** add a subdomain, so they cannot use the drop-in `/etc/caddy/apps/*.caddy`
mechanism (Caddy refuses a duplicate site address). Instead the route blocks are
woven into the core Caddyfile **for you** by `scripts/render-config.sh`:

- When `ENABLE_USER_FILTER=true`, it injects a `handle` for the user-directory
  search route → `127.0.0.1:${USER_FILTER_PORT}`.
- When `ENABLE_MEDIA_FILTER=true`, it injects `handle` blocks for the media
  download / thumbnail / preview_url routes → `127.0.0.1:${MEDIA_FILTER_PORT}`.

Both are placed ahead of the catch-all `handle /_matrix/* { reverse_proxy
127.0.0.1:8448 }`, so the more-specific routes win and all other Matrix traffic
goes straight to the homeserver. **Nothing is injected when a filter is off**, so
a disabled filter is never routed to a dead loopback port — the default chat
vhost is unchanged.

You don't edit the Caddyfile by hand. Just set the flag in `.env` and re-run the
installer (`./pocket.sh` → Install, or `bash scripts/install.sh --force`), which
re-renders the config and restarts the stack. To apply a change to an
already-installed stack directly:

```sh
scripts/render-config.sh        # re-injects (or removes) the routes from .env
scripts/start-stack.sh --restart
```

The rendered Caddyfile is validated fail-closed before it is served. Changing
`USER_FILTER_PORT` / `MEDIA_FILTER_PORT` is picked up automatically on the next
render — the injected `reverse_proxy` targets follow the configured ports.

---

## Notes

- Both bind `127.0.0.1` only and refuse to start otherwise — Caddy is the sole
  front door; the public edge never reaches them directly.
- They are supervised exactly like the rest of the stack (respawn on crash,
  identity-checked pidfile) and re-supervised on every `start-stack.sh` run, so
  they survive a reboot with the rest of the stack.
- Disable by setting the flag back to `false` and re-running with `--force`:
  render-config drops the injected route(s) automatically, so that traffic goes
  straight to the homeserver again. (The supervised filter process is left
  running until the next reboot or an explicit `ops/restart.sh`; with no route
  pointing at it, it just sits idle on loopback.)
