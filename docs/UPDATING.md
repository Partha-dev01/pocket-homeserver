# Updating

Every component pocket-homeserver fetches or builds is pinned in **one** file,
[`config/versions.env`](../config/versions.env): a version and (for binary
downloads) an exact `sha256`. Nothing is ever fetched "latest" — a pin is the only
thing that decides what you run. To change one safely, use the update tool rather
than hand-editing.

## See what's pinned

```sh
scripts/ops/update.sh --list
```

Shows every component with its tier, version, and checksum.

## Update a component (safe by default)

The tool is **dry-run unless you pass `--confirm`**:

```sh
# preview the plan (changes nothing)
scripts/ops/update.sh memos
scripts/ops/update.sh memos --to 0.30.0 --sha256 <hash>

# apply it
scripts/ops/update.sh memos --to 0.30.0 --sha256 <hash> --confirm
```

On `--confirm` it:

1. backs up `config/versions.env` (to `…​.bak-<UTC>`),
2. **(Matrix only)** snapshots the database first,
3. writes the new pin,
4. re-runs the component's install step — `fetch_verified` re-downloads and
   verifies the new artifact **fail-closed** (a wrong `--sha256` aborts here),
5. restarts the service and watches it for ~75 s,
6. **rolls back automatically** (restores the old pin, reinstalls, restarts) if
   the service crash-loops (goes `DEGRADED`).

### Getting the new `sha256`

Download the release artifact for **arm64 / aarch64** and run `sha256sum` on it,
or copy it from the project's published checksums. Source/tag builds (Gatus,
Pingvin, Linkding, SearXNG) have no `sha256` — they pin a git tag/ref, so omit
`--sha256`.

## Tiers (how a rollback behaves)

| Tier | Components | Rollback behaviour |
|---|---|---|
| binary / source | cloudflared, maddy, gatus, … | reinstalls the previous version + restarts |
| app | memos, vikunja, freshrss, linkding, pingvin, snappymail | same — but these have on-disk data, so back it up (`scripts/ops/backup-all.sh`) before a major bump |
| static | element, it-tools | files re-deployed; no service to restart |
| schema | Matrix (continuwuity) | the DB is **snapshotted first**. A downgrade after a schema migration is **not** auto-reversible — if the older build can't open the database, restore the snapshot with `scripts/ops/restore.sh` |

## After updating

```sh
scripts/ops/doctor.sh
```

A read-only check of config, storage tiers, the userland, services/ports, and any
crash-loop (`DEGRADED`) markers — it never prints secret values.

## Notes

- `maddy` ships with a **placeholder** `sha256`: set the real hash (of the arm64
  archive) before enabling email, or `fetch_verified` refuses to install it.
- Your own `.env` values still **override** the manifest, so you can pin or hold a
  component there if you need to.

See also the versioning policy in [CONTRIBUTING.md](../CONTRIBUTING.md) and the
failure-mode picture in [docs/RESILIENCE.md](RESILIENCE.md).
