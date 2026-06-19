# Honeypot offline geo / ASN datasets (DB-IP lite)

The honeypot can enrich each flagged scanner IP with **country + ASN + a
hosting/datacenter flag**, computed entirely **OFFLINE** — no live IP-intel
lookups (a device behind CGNAT often has metered/filtered outbound, and the
honeypot never connects back to a source). The watcher resolves every IP locally
against a static monthly dataset with a bisect.

**This is optional and off until you deploy a dataset.** pocket-homeserver ships
NO dataset — only this README. With no `*.csv.gz` present here the watcher never
imports the geo module and every lookup is a no-op (see the contract below).

## Attribution (REQUIRED — CC-BY 4.0)

> IP Geolocation by DB-IP (https://db-ip.com) — used under CC-BY 4.0.

The DB-IP **lite** databases are licensed **CC-BY 4.0**: free to use/redistribute
**with attribution**. Keep the line above wherever the data is surfaced (this file
satisfies the attribution requirement for the repo). License text:
https://creativecommons.org/licenses/by/4.0/

## Source URLs (free lite editions)

Current-month files (replace `YYYY-MM`):

    Country : https://download.db-ip.com/free/dbip-country-lite-YYYY-MM.csv.gz
    ASN     : https://download.db-ip.com/free/dbip-asn-lite-YYYY-MM.csv.gz

CSV layout (gzip'd, no header):

    country : start_ip,end_ip,country_code            (CC = ISO-3166-1 alpha-2)
    asn     : start_ip,end_ip,asn_number,"Org Name"   (org may contain commas)

Ranges are text IP addresses and cover **both IPv4 and IPv6**.

## Files in this directory

    dbip-country-lite.csv.gz   <- country dataset (renamed, month-agnostic)
    dbip-asn-lite.csv.gz       <- ASN dataset      (renamed, month-agnostic)

The `*.csv.gz` files are **git-ignored** (large + regenerable); only this README
is tracked. The watcher reads them from `HP_GEO_DIR`, which defaults to this
directory (`scripts/honeypot/geo/`); override `HP_GEO_DIR`/`HP_GEO_COUNTRY`/
`HP_GEO_ASN` only if you keep the datasets elsewhere.

## Deploying / refreshing the dataset

DB-IP publishes a fresh dataset each month. Download the two lite files and drop
them in this directory under the month-agnostic names above:

```sh
cd scripts/honeypot/geo
for kind in country asn; do
  for m in $(date +%Y-%m) $(date -d 'last month' +%Y-%m); do  # current, then fallback
    url="https://download.db-ip.com/free/dbip-${kind}-lite-${m}.csv.gz"
    if curl -fsSL -o "dbip-${kind}-lite.csv.gz" "$url" \
       && gunzip -t "dbip-${kind}-lite.csv.gz"; then
      echo "${kind}=${m}"; break
    fi
  done
done
```

(The current month 404s for a few days after the 1st — the loop falls back one
month.) Restart the watcher afterwards (`bash scripts/ops/restart.sh
honeypot-watcher`) so it picks up the new dataset.

## No-op contract

Enrichment is strictly **additive**: if `HP_GEO_DIR` is empty/unset or neither
dataset file is present, `scripts/honeypot/honeypot-watcher.py` never imports
`honeypot_geo.py` and every `geo_lookup()` returns `{}`. Classification, the
safelist, and all blocking decisions are **never** touched by geo — it only
annotates the ledger / alert / admin console. Deploying the watcher *without* the
dataset is byte-equivalent to a geo-less run; the hosting/DC flag is advisory only
(a datacenter ASN on a scanner hit is just a stronger signal, never an auto-action
input).
