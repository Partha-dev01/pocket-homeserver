# Restore + credential rotation

On-demand operator actions that complement the backup tooling (`docs/BACKUPS.md`)
and the admin panel (`docs/ADMIN.md`). All of these live in `scripts/ops/` and are
run by hand (or from `./pocket.sh` / the admin panel) — none of them is scheduled.

## Restore — `scripts/ops/restore.sh`

Rebuilds the Debian userland rootfs and the conduwuit DB from the snapshots that
`backup-all.sh` / `backup-db.sh` wrote to `${BACKUP_DIR}`.

- **Dry run by default.** With no flags it only prints the plan and changes
  nothing.
- To actually restore you must pass the explicit confirm phrase:

  ```sh
  bash scripts/ops/restore.sh --confirm=ERASE-AND-RESTORE
  ```

- Picks the **latest** rootfs + DB archive by ISO-8601 filename sort (not
  `ls -t`); override with `--rootfs=<path> --db=<path>`.
- Verifies the `.sha256` sidecars **fail-closed**, scans each archive for
  zip-slip (rejects any member with a `..` component or an absolute path), and
  extracts `--no-same-owner`.
- Encrypted (`.age`) archives are decrypted to a temp plaintext first — set
  `BACKUP_AGE_IDENTITY` in `.env` to your age **private** key file (kept OFF the
  backup volume). The temp plaintext is removed after extraction.
- The existing rootfs is **renamed aside** as `debian.broken-<UTC>` (never
  deleted), so a bad restore is one `mv` back. The script prints the rollback
  command when it finishes.

## Rotations

| Script | Rotates | Requires |
| --- | --- | --- |
| `rotate-admin-password.sh` | web admin panel login password | always |
| `rotate-registration-token.sh` | Matrix shared registration token | always |
| `rotate-tunnel-token.sh` | Cloudflare Tunnel token (`CF_TUNNEL_TOKEN`) | manual CF-dashboard step first |
| `rotate-authgw-rs.sh` | auth-gateway RS256 OIDC signing key (kid-overlap) | `ENABLE_AUTH_GATEWAY=true` |
| `rotate-adminbot-token.sh` | optional Matrix admin-bot access token | `ENABLE_ADMINBOT=true` |
| `rotate-all.sh` | the first two always + the auth-gw/admin-bot ones when enabled | — |

### Tunnel token — `rotate-tunnel-token.sh`

1. In the Cloudflare dashboard, rotate or recreate the tunnel (the old token
   becomes invalid). Re-add the public hostname → `http://localhost:${CADDY_PORT}`.
2. Run the script and paste the new token at the hidden prompt (it is never
   echoed and never on argv), or pipe it on stdin:

   ```sh
   bash scripts/ops/rotate-tunnel-token.sh < new-token.txt
   ```

   It rewrites the `CF_TUNNEL_TOKEN` line in `.env` (atomic, 0600; previous `.env`
   backed up under `${BACKUP_DIR}/config`) and restarts the tunnel.

### Auth-gateway RS256 key — `rotate-authgw-rs.sh`

Two-phase, zero-downtime rotation with a JWKS overlap window:

```sh
bash scripts/ops/rotate-authgw-rs.sh new        # mint new key, keep old in JWKS
# … set AUTHGW_OIDC_RS_KID + AUTHGW_OIDC_RS_OLD_KEYS as printed, restart auth-gw,
#   wait past the token TTL + the clients' JWKS cache …
bash scripts/ops/rotate-authgw-rs.sh finalize   # drop the old key
```

### Rotate everything — `rotate-all.sh`

Runs each available rotation independently and prints a pass/skip/fail summary.
The tunnel token is intentionally excluded (it needs the manual dashboard step).
