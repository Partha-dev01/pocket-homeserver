# Tailscale — userspace mesh VPN (no public hostname)

Tailscale joins the phone to your private **tailnet** (a WireGuard-based overlay
network) so your own devices can reach it directly — sidestepping CGNAT entirely,
without a Cloudflare hostname. It is **optional and OFF by default** — enable it with
`ENABLE_TAILSCALE=true`.

> **Read the trust-boundary section before enabling.** Anything reachable over the
> tailnet **completely bypasses** Cloudflare Access and the Cloudflare Tunnel. Your
> **tailnet ACL** becomes the only network gate for that traffic.

## How it installs

`scripts/steps/90-install-tailscale.sh` is a **core step that self-gates** on
`ENABLE_TAILSCALE` (like the Syncthing step-89): `install.sh` runs it unconditionally
and it no-ops when disabled. It is **not** in `app_order` and has **no Caddy vhost / no
public hostname** — Tailscale is its own transport.

The pinned tarball is fetched and verified fail-closed via `fetch_verified`:

- `TS_VER=1.98.4`
- `TS_SHA256=3cb068eb1368b6bb218d0ef0aa0a7a679a7156b7c979e2279cc2c2321b5f05c7`

It extracts the exact `tailscale_${TS_VER}_arm64/tailscaled` + `…/tailscale` binaries
(pinned inner paths) into the userland at `/opt/tailscale`.

## Userspace networking (load-bearing — no root, no TUN)

The phone is unrooted and the proot userland cannot open `/dev/net/tun`, so
`tailscaled` runs in **userspace-networking mode**:

```
tailscaled --tun=userspace-networking \
           --statedir=<ext4> --socket=<ext4>/tailscaled.sock \
           --socks5-server=127.0.0.1:1055 \
           --outbound-http-proxy-listen=127.0.0.1:1055
```

- **No `/dev/net/tun`, no root** — mandatory on this platform.
- The tailnet is exposed to local apps as a **SOCKS5 + outbound HTTP proxy** on a
  single loopback port (default `127.0.0.1:1055`; Tailscale 1.20+ shares both on one
  listener). To have a local app reach a tailnet peer, point it at that proxy.
- `TS_SOCKS5` is env-overridable but the script **asserts it is a loopback literal**
  (`127.0.0.1`/`[::1]`) before launch and refuses any non-loopback address — the
  proxy can never be exposed on a real interface.
- The control socket lives on ext4 (the default `/var/run` is not writable for a
  non-root proot user).
- `GOMEMLIMIT` (default `128MiB`) caps the Go heap so a sync/route storm cannot OOM
  the phone (soft limit — the runtime GCs harder rather than ballooning).

## State + auth key (load-bearing)

- **State dir on ext4.** The node key, identity, and prefs live on **ext4** at
  `$HOME/.pocket/tailscale`. This is a tiny but integrity-critical store; the script
  **refuses `DATA_DIR` (the exFAT SD) fail-closed** (with symlink resolution) — the
  node key store would corrupt there.
- **Auth key off-argv.** The node joins with `tailscale up --auth-key file:<path>`:
  the `file:` scheme means only the **path** appears on argv, never the key. Mint an
  auth key in the Tailscale admin console (Settings → Keys → Generate auth key) and
  store it in **one** of (both 0600):
  - `${DATA_DIR}/secrets/tailscale.env` — line `TS_AUTHKEY=tskey-auth-...`, or
  - `$HOME/.pocket/tailscale/authkey` — the raw key on one line.
- **Fail-closed if no key.** Without a key the daemon is supervised but the script
  **refuses to bring the node up half-configured** and tells you exactly where to put
  the key, then re-run.
- The node is named on your tailnet via `--hostname` (default `pocket-<first label of
  your domain>`; override with `TS_HOSTNAME`). `--accept-dns=false` is set so the
  phone's own resolver is untouched. The `up` is wrapped in `run_once`
  (`tailscale-up.done` marker) — to re-auth after key rotation, update the secret and
  `rm -f "$POCKET_STATE_DIR/tailscale-up.done"`, then re-run the step.

## Trust boundary (read this — restated loud)

Anything reachable over the tailnet **bypasses Cloudflare Access and the Cloudflare
Tunnel completely.** CF Access only gates `*.${DOMAIN}`. Your **tailnet ACL**
(Tailscale admin console) is the **only** network gate for tailnet traffic. The
default "allow all within tailnet" means every device on your tailnet can reach this
box's loopback services with no further network auth — **lock the ACL down**.
Per-app native logins still apply on top, but do not treat them as the network
boundary. This is the single most important operational fact about enabling
Tailscale here (see [APP_AUTH.md](APP_AUTH.md)).

## What it unlocks

- Reaching the phone's loopback services from your own devices **without** a public
  Cloudflare hostname — useful for admin/debug surfaces you'd rather not expose at the
  edge at all.
- A real **LAN-style `:53` DNS resolver**: AdGuard Home cannot be a `:53` sinkhole
  over the CGNAT tunnel, but over a tailnet you *can* carry UDP to a high port on the
  phone. See [ADGUARD.md](ADGUARD.md).

## CGNAT interaction

Tailscale is *the* CGNAT sidestep: WireGuard over the tailnet (with DERP relays as a
fallback) reaches the phone with no inbound port and no Cloudflare hostname. The
~100 MB Cloudflare-tunnel body cap does not apply to tailnet traffic (it does not use
the tunnel).

## Resource & Risk

| Dimension | Assessment |
|---|---|
| **RAM** | Capped via `GOMEMLIMIT` (default 128 MiB); a userspace WireGuard endpoint is light at idle. |
| **CPU / thermal** | Userspace networking does crypto in-process, so high-throughput transfers cost more CPU than a kernel TUN would — fine for admin/sync, not a high-bandwidth media path. |
| **Storage** | Tiny: node key + identity + prefs on ext4. |
| **Trust boundary** | ⚠️ **Tailnet bypasses CF Access + the tunnel** — the tailnet ACL is the only gate. Lock it down. |
| **Secrets** | Auth key off-argv via `--auth-key file:`; stored 0600. Re-auth by clearing the `run_once` marker. |
| **Upgrade fragility** | Low: bump `TS_VER` + `TS_SHA256` together and re-run; state persists on ext4. |

## Upgrades / re-pin recipe

1. Get the new hash from `https://pkgs.tailscale.com/stable/tailscale_<ver>_arm64.tgz.sha256`
   (or `sha256sum` a trusted tarball).
2. Bump `TS_VER` + `TS_SHA256` **together** in `config/versions.env`.
3. Re-run `scripts/steps/90-install-tailscale.sh` (state on `$HOME/.pocket/tailscale`
   persists; no re-auth needed unless you cleared the marker).

## Enabling

```ini
# .env
ENABLE_TAILSCALE=true
```

Put your auth key in `${DATA_DIR}/secrets/tailscale.env` (`TS_AUTHKEY=tskey-auth-...`,
0600), then `./pocket.sh` → Install (or `scripts/install.sh`). Lock down your tailnet
ACL in the Tailscale admin console. To disable: set `ENABLE_TAILSCALE=false` and stop
`tailscaled` (`scripts/ops/restart.sh` / `start-stack.sh`).

## See also

- [APP_AUTH.md](APP_AUTH.md) — the tailnet-bypasses-the-edge trust boundary.
- [ADGUARD.md](ADGUARD.md) — the resolver that needs Tailscale for a real `:53`.
- [SECURITY.md](SECURITY.md) — the loopback-only edge model this sits alongside.
- [UPDATING.md](UPDATING.md) — version pins + `scripts/ops/update.sh`.
