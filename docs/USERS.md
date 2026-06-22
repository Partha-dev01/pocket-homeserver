# Matrix user management

continuwuity (the homeserver this stack runs) does **not** expose a full Synapse
HTTP admin API. It administers users through an **admin command room**: you send a
command as a message in `#admins:<your-domain>` and the server's admin bot replies
in the room. pocket-homeserver wraps that channel so you can manage users from the
admin panel or the CLI — without learning the room dance.

Enable it with `ENABLE_USER_ADMIN=true` (in `.env` or `./setup.sh`) and re-run the
installer. A **Users** page then appears in the [admin panel](ADMIN.md).

## What you can do

| Action | Panel / CLI | continuwuity command run |
|---|---|---|
| List users | Users page / `ops/user-list.sh` | `admin users list-users` |
| Create a user | `ops/user-create.sh <localpart>` | `admin users create-user <localpart>` |
| Reset a password | `ops/user-reset-password.sh <localpart>` | `admin users reset-password <localpart>` |
| Suspend (read-only) | `ops/user-suspend.sh <user>` | `admin users suspend <mxid>` |
| Unsuspend | `ops/user-unsuspend.sh <user>` | `admin users unsuspend <mxid>` |
| Deactivate (close) | `ops/user-deactivate.sh <user>` | `admin users deactivate <mxid>` |
| Mint invite tokens | `ops/user-invite.sh [N]` | (token admin API, via `mint-invite-token.sh`) |

`create-user` and `reset-password` let the **server generate** the password and
return it in its reply — pocket-homeserver never puts a password on a command line.

## How it works

[`scripts/lib/matrix_admin.py`](../scripts/lib/matrix_admin.py) reads the operator's
access token + MXID from the 0600 `${DATA_DIR}/secrets/admin-credentials.env`
(written by [`bootstrap/create-admin.sh`](../scripts/bootstrap/create-admin.sh)),
resolves the admin room (`#admins:` then `#admin:`, or `$ADMIN_ROOM_ID`), makes sure
the account has joined it, sends the command, and **relays the bot's reply
verbatim**. It never parses the reply, so it keeps working as continuwuity's wording
or subcommand set evolves. The token is sent only in the `Authorization` header.

In the panel, every write op requires the CSRF token **plus a password re-auth**,
is **audit-logged**, and **deactivation additionally requires retyping the exact
user id**. The CLI scripts validate the localpart/MXID strictly (no shell, fixed
argv) before handing it to the homeserver.

### Prerequisites

- The account in `admin-credentials.env` must be a **server admin**. The first user
  registered on a fresh homeserver is automatically the admin and is auto-invited to
  the admin room — that's the bootstrap admin
  ([`create-admin.sh`](../scripts/bootstrap/create-admin.sh)). If yours isn't, the
  bot will reply with a permission error (which you'll see verbatim), and you must
  promote it first.
- The homeserver must be up (these talk to it over loopback).

### Version / config knobs

continuwuity issues admin commands as `!admin <args>` (the default). If your build
expects **bare** commands in the admin room, set `MATRIX_ADMIN_PREFIX=` (empty) in
`.env`. If the admin room isn't discoverable by alias, set
`ADMIN_ROOM_ID=!yourRoom:your.domain`. These are the two knobs that absorb version
differences.

## Resource & Risk

- **Generated passwords land in the admin room history.** When the server creates or
  resets a password it prints it in its reply, which is a normal message persisted in
  `#admins:` (typically unencrypted). Treat the admin room as sensitive: keep its
  membership to operators, and rotate/forget credentials you've handed off. This is
  inherent to continuwuity's admin-room model, not something pocket-homeserver can
  hide.
- **Deactivation is effectively irreversible** — the account can no longer log in;
  "re-enabling" means creating it again. Suspension is the reversible middle ground
  (read-only). The panel gates deactivation behind a retype-to-confirm + password.
- **Live behaviour is operator-verified.** This drives the homeserver over the
  network; it can only be fully exercised against a running phone. If a command
  returns "no reply within Ns", open the admin room in Element to see what the bot
  actually did, and check `MATRIX_ADMIN_PREFIX` / `ADMIN_ROOM_ID`.
- **No password is ever logged or placed on argv** by these scripts; the admin token
  stays in its 0600 file and the `Authorization` header.
