# Operator admin bot (optional)

An optional Matrix bot that lets **you — and only you** — drive the stack from a
private chat room: `!status`, `!users`, `!invite-token`, `!restart-stack`, and a
few more. It is **off by default** (`ENABLE_ADMINBOT`). It is the chat-side
counterpart to the web admin panel ([ADMIN.md](ADMIN.md)).

It runs **Termux-native** (it orchestrates the host — it shells out to
`scripts/ops/*` and reads the loopback Matrix API), has **no inbound listener**,
and makes **no Caddy change** — zero new attack surface.

## Security model

This is the whole trust boundary, so it is worth stating plainly:

- **One operator, exact match.** The bot acts only on messages whose sender is
  **exactly** `ADMIN_MXID` (no prefix/substring match). An empty `ADMIN_MXID`
  fails **closed** — it refuses every command.
- **One room.** It listens only in `ADMIN_ROOM` (a private room with just you and
  the bot).
- **Fixed command table.** Each `!command` maps to a fixed `scripts/ops/*` argv —
  run with `subprocess` (a list argv, **no `shell=True`**), and the resolved path
  is asserted to stay under `scripts/`. **No chat text is ever interpolated into a
  shell.**
- **Destructive ops are confirm-gated.** `!restart-stack` must be re-sent within
  60 s to actually run.
- **Secrets off argv.** The bot token, room id, and your MXID live only in the
  `0600` `${DATA_DIR}/secrets/adminbot.env`, sourced in-process by the launcher —
  never in `.env`, never on a command line. The token is used only in an
  `Authorization` header and is never logged. Privileged queries (e.g. `!users`)
  need an optional `ADMIN_TOKEN`; without it they **fail loud** rather than
  downgrading to the bot's own scope.
- **Audited.** Every state-changing or secret-revealing command is written to the
  admin audit log before it runs.

## Command surface

| Command | What it does | Notes |
|---|---|---|
| `!help` / `!whoami` | command list / bot identity | read-only |
| `!status` | `ops/status.sh` output | read-only |
| `!users` | users sharing a room with you | needs `ADMIN_TOKEN` |
| `!invite-token` | reveal the current registration token | audited; shown only in the ops room |
| `!private-list` / `!private-add <mxid>` / `!private-remove <mxid>` | manage the user-filter private list | see [FILTERS.md](FILTERS.md) |
| `!backup-now` / `!full-backup` / `!rotate-backups` | run the backup ops scripts | audited |
| `!restart-stack` | restart the core stack | **confirm-gated** (re-send within 60 s) |

## Setup

1. **Create the bot's Matrix account** — register an `@adminbot` account (e.g. with
   an invite token from [`bootstrap/mint-invite-token.sh`](../scripts/bootstrap/mint-invite-token.sh)),
   and obtain its access token (the off-argv recipe in
   [CHATBOTS.md](CHATBOTS.md#register-the-bot-account--mint-its-token-off-argv)
   works for any bot account).
2. **Create a private admin-ops room** with only you and `@adminbot` in it, and
   note its room id (`!opaque:your-server`).
3. **Enable + configure.** Set `ENABLE_ADMINBOT=true` in `.env` (or pick it in
   `./setup.sh`), then run the installer once — it seeds a `0600`
   `${DATA_DIR}/secrets/adminbot.env` template and stops. Fill it in:

   ```sh
   BOT_TOKEN=<@adminbot access token>
   ADMIN_ROOM=!yourroom:your-server
   ADMIN_MXID=@you:your-server          # ONLY this sender is obeyed
   ADMIN_TOKEN=                         # optional; enables !users etc.
   ```

   Re-run the installer (`./pocket.sh` → Install, or `bash scripts/install.sh --force`)
   to supervise the bot. Then say `!help` in the ops room.

> **Tip:** if you also use the web panel's *admin bot* widget, set `ADMIN_MXID` to
> the same account whose token is in `admin-credentials.env` (the bootstrap admin,
> `@admin` by default) — the panel sends its read-only commands as that operator,
> so the bot's gate must name the same MXID.

## Restart / rotate

- Restart: `bash scripts/ops/restart.sh adminbot` (or the panel's health list).
- Rotate the bot token with `bash scripts/ops/rotate-adminbot-token.sh` (see
  [RESTORE_AND_ROTATION.md](RESTORE_AND_ROTATION.md)).
- Logs: `${POCKET_LOG_DIR}/adminbot.log`.

## The web panel widget

When `ENABLE_ADMINBOT` is on, the admin panel dashboard shows a small **admin bot**
strip of buttons (`!status`, `!users`, `!private-list`, `!invite-token`, `!whoami`).
Each POSTs **one allowlisted, read-only** command to the ops room as you; the bot
replies in Element (the panel doesn't show the reply). Destructive commands are
deliberately **not** offered there — run those in Element so the bot's confirm gate
+ audit trail apply.
