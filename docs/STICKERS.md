# Sticker picker (optional)

A Matrix sticker picker for your Element clients: the third-party **Maunium
stickerpicker** widget, plus a small native backend that lets users **upload**
their own stickers and search **Giphy**, plus an **importer bot** for mobile
clients whose widget WebView can't open a file chooser.

Off by default. Enable with `ENABLE_STICKERS=true` and supply a Matrix service
token (and optionally a free Giphy key + bot creds). See `docs/SETUP.md`.

## What it is

| Piece | Where it runs | What it does |
|------|----------------|--------------|
| Picker widget (Maunium, **AGPL**) | static SPA in the userland, served by Caddy on `stickers.${DOMAIN}` | the in-Element sticker UI |
| `sticker-backend.py` | **Termux-native**, loopback `127.0.0.1:8451` | upload→Matrix media, Giphy search/pick proxy, per-user packs |
| `importer-bot.py` | **Termux-native** Matrix bot (optional) | DM it an image to import it; `!help/!list/!random/!delete` |

The widget runs inside Element's iframe but fetches its data (`api/giphy-search`,
`api/giphy-pick`, `api/upload-sticker`, `api/user-packs`) **relative** to where
it is served, so Caddy maps `…/api/*` on the sticker vhost to the loopback
backend. The backend holds the **server-side** Giphy key and the **Matrix
service token** (a browser can't keep a secret), uploads media to your own
homeserver so it renders even with federation off, and writes per-user packs
under `${DATA_DIR}/sticker/packs/`.

## Licensing (read this)

The picker UI is **not** part of this repo. It is the upstream
[Maunium stickerpicker](https://github.com/maunium/stickerpicker) (GNU **AGPL
v3**, by Tulir Asokan). The installer **FETCHES** it at install time and serves
its `web/` assets; we do not vendor its source (that would entangle MIT with
AGPL). Only our thin config lives in `scripts/sticker/widget/`. The upstream
`LICENSE` travels with the fetched checkout under `${DATA_DIR}/stickerpicker-src`.

## Configuration

In `.env` (the setup wizard prompts for these):

```sh
ENABLE_STICKERS=true
# A Matrix access token for an account on THIS homeserver that may upload media.
STICKER_SERVICE_TOKEN=        # required
# Free Giphy API key (https://developers.giphy.com). Empty disables the Giphy tab.
GIPHY_API_KEY=                # optional
# Optional DM-import bot (a second Matrix account):
STICKER_BOT_TOKEN=
STICKER_BOT_MXID=@sticker-importer:${MATRIX_SERVER_NAME}
STICKER_BOT_NAME=sticker-importer
# Optional auto-registration of the widget on an admin account:
STICKER_ADMIN_TOKEN=
STICKER_ADMIN_MXID=@admin:${MATRIX_SERVER_NAME}
# Identity-verification mode: log (default, migration-safe) | enforce.
STICKER_IDENTITY_MODE=log
# Pin the upstream picker ref (bump to upgrade, then re-run --force).
STICKERPICKER_REF=master
```

Secrets are written to a 0600 `${DATA_DIR}/secrets/sticker.env` by the install
step and sourced by the launchers — they never appear on a command line.

## Signed widget URLs (identity)

The picker forwards the widget URL's `matrix_user_id` (substituted by Element
from the authenticated session) to the backend. With federation off the Matrix
widget OpenID path is unavailable, so each per-user widget URL carries a signed
`<mxid>|<hmac>` (HMAC-SHA256 keyed by a per-deployment secret in
`${DATA_DIR}/secrets/sticker-url.secret`). The backend verifies it before any
pack write.

Roll it out **`log` → `enforce`**: start in `log` (unsigned/legacy URLs are
allowed but logged) so a stale cached widget URL can't break the picker
mid-migration; mint fresh widget URLs for every user; then set
`STICKER_IDENTITY_MODE=enforce` and re-run the step with `--force`.

## Pack model

Per-user packs live at `${DATA_DIR}/sticker/packs/users/<mxid>/`, with thumbnails
under `packs/thumbnails/`. Every user's packs are listed in the global
`packs/index.json`, so on a multi-user server they are visible to every picker
user. That is acceptable for a small invite-only server; do not run this on a
public homeserver without per-user pack isolation.

## Cloudflare

Add a Public Hostname `stickers.${DOMAIN} → http://localhost:${CADDY_PORT}` in
the Tunnel config and a Cloudflare Access policy protecting it. These are
dashboard steps the installer cannot do for you.

## Upgrading

Bump `STICKERPICKER_REF` and re-run `scripts/install.sh --force` (or just the
step). Re-verify the widget renders in a real Element client afterward.
