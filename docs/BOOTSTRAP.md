# Matrix bootstrap — seed an admin, Spaces, and rooms (optional)

pocket-homeserver ships an **optional, idempotent** Matrix bootstrap: a set of
small helpers that run *after* the homeserver is up and seed the things a fresh
server usually wants — an admin account, a community **hub Space** with a few
rooms, an **admin-only announcements** room, and (optionally) avatars.

It is **off by default**. Enable it with `ENABLE_BOOTSTRAP=true` in `.env`.

Every helper is **idempotent**: rooms are detected by alias and reused, the admin
account logs in if it already exists, and the welcome message is posted only once.
Re-running is safe and fast.

## What it does

The install step `scripts/steps/79-install-bootstrap.sh` self-gates on
`ENABLE_BOOTSTRAP` and runs the helpers in order:

| Helper | What it does |
|---|---|
| `scripts/bootstrap/create-admin.sh` | Registers `@${ADMIN_MATRIX_USER}:${MATRIX_SERVER_NAME}` (or logs in if it exists). Saves a `0600` credentials file (`${DATA_DIR}/secrets/admin-credentials.env`) the other helpers read. |
| `scripts/bootstrap/create-spaces.sh` | Creates the hub Space + a few public rooms + one private, E2EE room, and links the public rooms into the Space. Writes an audit trail. |
| `scripts/bootstrap/create-announcements.sh` | Creates a public room where everyone can read but only the admin can post (power level 100), links it into the Space, posts a one-time welcome. |
| `scripts/bootstrap/make-avatars.py` + `set-avatars.py` | (Optional, `BOOTSTRAP_AVATARS=true`) Generate simple circular avatars and set them on the admin user, the Space, and the announcements room. |

There is also a standalone helper you run on demand:

| Helper | What it does |
|---|---|
| `scripts/bootstrap/mint-invite-token.sh [N]` | Mints `N` single-use registration (invite) tokens (default `1`), each self-expiring after `INVITE_TOKEN_DAYS` (default 7). Appends them to `${DATA_DIR}/secrets/invite-tokens.txt` (`0600`). |

All helpers run **Termux-native** and talk to the homeserver over the loopback
client-server API (`http://127.0.0.1:8448`). None of them enter the proot userland.

## Prerequisites

1. The homeserver must be **running** (the helpers wait for it).
2. Registration must be **open with a token**. Mint/enable one first:

   ```sh
   bash scripts/ops/rotate-registration-token.sh
   ```

   That writes `${DATA_DIR}/secrets/registration-token.txt` (`0600`) and turns on
   `allow_registration` in the deployed config. `create-admin.sh` reads that token
   from the file (never from a command line). After bootstrap you can close
   registration again — re-running `scripts/install.sh` resets it to closed.

## Enabling it

1. Set in `.env`:

   ```sh
   ENABLE_BOOTSTRAP=true
   # The localpart of the Matrix admin (defaults to "admin").
   ADMIN_MATRIX_USER=admin
   # Optional: generate + upload avatars (needs Pillow: pip install Pillow).
   BOOTSTRAP_AVATARS=false
   ```

2. (Re-)run the installer. The bootstrap step self-gates on the flag:

   ```sh
   ./pocket.sh        # menu → Install   (or: bash scripts/install.sh --force)
   ```

   Or run the bootstrap step directly once the stack is up:

   ```sh
   bash scripts/steps/79-install-bootstrap.sh
   ```

## Customizing the structure

The Space, rooms, and copy are a **template** — override them from `.env` (the
helpers read these from the environment, with neutral defaults):

```sh
MATRIX_SPACE_ALIAS=hub
MATRIX_SPACE_NAME="Community Hub"
MATRIX_SPACE_TOPIC="The landing space for community chat."

MATRIX_PRIVATE_ROOM_ALIAS=private      # set "" to skip the private E2EE room
MATRIX_PRIVATE_ROOM_NAME="Private room"

MATRIX_ANNOUNCE_ALIAS=announcements
MATRIX_ANNOUNCE_NAME=announcements
MATRIX_ANNOUNCE_WELCOME="Welcome to #announcements. Only the admin can post here."
```

To change the public child rooms, edit the `PUBLIC_ROOMS=( ... )` array near the
top of `scripts/bootstrap/create-spaces.sh` (one `alias|name|topic` row each).

## Inviting users

After bootstrap, hand each new user a single-use token:

```sh
bash scripts/bootstrap/mint-invite-token.sh 5     # mint 5 tokens
cat "${DATA_DIR}/secrets/invite-tokens.txt"       # one line per token + expiry
```

Share **one line per invited user** over a private channel. Each token is one-use
and self-expires.

## Secrets and security

- The **admin password** and the **registration token** are read from `0600`
  files under `${DATA_DIR}/secrets` (or the environment) and are **never passed on
  argv**.
- `create-admin.sh` mints a privileged **admin access token** and saves it to
  `${DATA_DIR}/secrets/admin-credentials.env` (`0600`). The other helpers source
  that token; anyone able to read the file can act as the admin. Keep it `0600`.
- The web admin panel reads the same `admin-credentials.env` / `registration-token.txt`
  files (see `docs/ADMIN.md`).
