# Sticker picker widget assets

The sticker picker UI is the **third-party Maunium stickerpicker**
(https://github.com/maunium/stickerpicker) by Tulir Asokan, licensed under the
**GNU AGPL v3**. pocket-homeserver does **NOT** vendor (copy) its source into
this repo — that would entangle our MIT licensing with the AGPL and bloat the
tree. Instead the installer **FETCHES** the upstream picker at install time and
serves it behind Caddy.

This directory contains only **OUR thin config** plus this README. With no
upstream checkout present, there is no picker to serve — `scripts/install.sh`
(via `scripts/steps/82-install-stickers.sh`, gated on `ENABLE_STICKERS`) clones
the pinned upstream tag and copies its `web/` assets into the userland.

## What the installer fetches (upstream, AGPL)

`scripts/steps/82-install-stickers.sh`:

1. clones `https://github.com/maunium/stickerpicker` at the pinned tag
   (`STICKERPICKER_REF`, env-overridable) into `${DATA_DIR}/stickerpicker-src`,
2. copies the upstream `web/` static assets into the userland at
   `/var/www/stickerpicker` (the picker is a static SPA — no build step for the
   reference deployment),
3. drops `packs/index.json` from `index.json.tmpl` in this directory if the
   picker doesn't ship one (an empty pack list the backend grows as users
   upload),
4. seeds the secrets file, supervises the backend + importer bot, writes the
   Caddy vhost, and registers the widget on the admin account via the Matrix API.

The picker's own `LICENSE` (AGPL) travels with the fetched checkout — the
installer never strips it.

## Files in this directory (OURS)

    README.md          this file
    index.json.tmpl    default empty packs index seeded into the picker if absent

## How the widget talks to our backend

The upstream picker fetches `api/giphy-search`, `api/giphy-pick`,
`api/upload-sticker`, `api/user-packs` **relative** to wherever it is served, so
no JS edit is needed. Caddy maps `…/api/*` on the sticker vhost to the loopback
`sticker-backend.py` (default `127.0.0.1:8451`), which holds the server-side
Giphy key + the Matrix service token and writes per-user packs under
`${DATA_DIR}/sticker/packs/`. See `docs/STICKERS.md`.

## Upgrading the picker

Bump `STICKERPICKER_REF` in `.env` (or pass it to the step) and re-run the
install step with `--force`. Re-verify the widget renders in a real Element
client afterwards — Element validates widget content client-side.
