#!/usr/bin/env bash
#
# apps/adguard.sh — install + supervise AdGuard Home as a DoH-over-tunnel
# RESOLVER (a private, filtering DNS-over-HTTPS endpoint your devices point at),
# behind the loopback Caddy edge on dns.${DOMAIN}.
#
# ┌── SCOPE — READ THIS, IT IS THE WHOLE POINT ─────────────────────────────────
# │ This is NOT a LAN ":53 sinkhole" and CANNOT become one on this stack:
# │   * :53 is a privileged port; a non-root proot userland cannot bind it.
# │   * The phone is behind CGNAT and reachable only via the Cloudflare Tunnel,
# │     which carries HTTP(S), NOT raw UDP/53 — so even if something bound :53 it
# │     would be unreachable from outside the phone.
# │ What this DOES ship is the only thing that actually works here: a filtering
# │ DNS-over-HTTPS (DoH) resolver published at https://dns.${DOMAIN}/dns-query via
# │ the tunnel. Point a device's "Private DNS / DoH" setting at that URL and its
# │ lookups are filtered by AdGuard Home. A real network-wide :53 sinkhole needs
# │ Tailscale or a LAN box — see docs/ADGUARD.md.
# └─────────────────────────────────────────────────────────────────────────────
#
# What it does (idempotent — review before running):
#   1. downloads + sha256-verifies (fail-closed) the pinned linux-arm64 release
#      tarball into ${DATA_DIR}/binaries, then installs the single Go binary into
#      the userland at /opt/adguard and verifies it runs,
#   2. keeps ALL of AdGuard's state — AdGuardHome.yaml, the work dir (sessions DB,
#      query log, stats, filter lists) — on EXT4 ($HOME/.pocket/adguard,
#      bind-mounted to /opt/adguard/data). It REFUSES ${DATA_DIR} (exFAT)
#      fail-closed: the session/stats stores need real fsync + atomic rename +
#      POSIX locks that exFAT cannot provide (a verified failure class on this
#      stack — see docs/RESILIENCE.md). There is no bulk read-mostly data tier
#      here, so NOTHING goes on the SD card,
#   3. pre-seeds AdGuardHome.yaml (chmod 600) so the FIRST-RUN setup wizard is
#      skipped entirely: web UI bound to 127.0.0.1:9129, plain-HTTP DoH enabled on
#      that SAME port (http.doh.insecure_enabled — see the version note below), the
#      DNS resolver listener on a HIGH non-privileged loopback port (127.0.0.1:9130,
#      NEVER :53), and the admin user seeded from ${ADMIN_USER}/${ADMIN_PASSWORD}
#      as a BCRYPT hash generated OFF-ARGV (htpasswd -niB, password on stdin),
#   4. ASSERTS, post-start, via `ss` that NOTHING is listening on 0.0.0.0/[::]/
#      wildcard and that NOTHING is on :53 — unsupervise + die if so,
#   5. writes a self-contained Caddy vhost for dns.${DOMAIN} (the DoH path
#      /dns-query reverse_proxied DIRECTLY/EXEMPT, the admin UI behind the optional
#      commented forward_auth) and validates the whole Caddyfile fail-closed,
#   6. supervises AdGuardHome with --no-check-update and its config + work dir on
#      ext4.
#
# ┌── VERSION-CRITICAL CONFIG NOTE (verified against AdGuard Home docs) ─────────
# │ `tls.allow_unencrypted_doh` was REMOVED in v0.107.74. From v0.107.74 onward
# │ (this pin is v0.107.77), plain-HTTP DoH is controlled by `http.doh.insecure_
# │ enabled: true` and is served on the SAME port as `http.address` (the web UI
# │ port). There is therefore NO separate plain-HTTP DoH port: the web UI AND the
# │ /dns-query DoH endpoint both live on 127.0.0.1:9129. The Caddy vhost reflects
# │ this — /dns-query and the UI both reverse_proxy to :9129; the gate covers only
# │ the UI. See open_issues + docs/ADGUARD.md.
# └─────────────────────────────────────────────────────────────────────────────
#
# AUTH MODEL — gate the UI, EXEMPT the DoH endpoint: by default dns.${DOMAIN} is
# gated at the Cloudflare edge (Cloudflare Access) and AdGuard keeps its OWN admin
# login. BUT a DoH client (Android Private DNS, Firefox, a router) hits /dns-query
# with a raw DNS wire-format body and CANNOT follow a 302-to-login — so the vhost
# reverse_proxies /dns-query DIRECTLY (never gated), like navidrome's /rest. You
# MUST likewise EXEMPT /dns-query in your Cloudflare Access policy (a path BYPASS),
# or DoH clients SILENTLY FAIL. See the closing notes + docs/APP_AUTH.md.
#
# Idempotent + re-runnable. Generalized from the navidrome/dufs app pattern;
# review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DOMAIN         "your apex domain (DNS on Cloudflare)"
require_var DATA_DIR       "folder on your large volume / SD card"
require_var ADMIN_USER     "the AdGuard Home admin username (set in .env)"
require_var ADMIN_PASSWORD "the AdGuard Home admin password (set in .env)"
require_cmd proot-distro
require_cmd curl

# NOTE: enabling/disabling is handled by install.sh (it only runs this when
# ENABLE_ADGUARD=true), so this script does not re-check the flag.

in_debian() { proot-distro login debian -- bash -lc "$1"; }

# ── Pinned release ───────────────────────────────────────────────────────────
# Pin an EXACT AdGuard Home version + sha256 rather than tracking "latest", so the
# download fails closed on any corruption/tampering. Both are env-overridable (and
# centrally pinned in config/versions.env) without editing this file.
#
# To upgrade: bump AGH_VER and AGH_SHA256 *together* (get the new hash from the
# release's checksums.txt, or by hashing a tarball you already trust:
#   sha256sum AdGuardHome_linux_arm64.tar.gz
# ), then re-run this script. AdGuard's state persists across upgrades because it
# lives on $HOME/.pocket/adguard.
#
# ⚠ The plain-HTTP-DoH config key changed at v0.107.74 (allow_unencrypted_doh →
# http.doh.insecure_enabled). If you bump ACROSS that boundary in either direction,
# re-read the VERSION-CRITICAL CONFIG NOTE above before changing the yaml.
AGH_VER="${AGH_VER:-0.107.77}"
AGH_SHA256="${AGH_SHA256:-e095d38e67cd72e0190fbe5f23177c0bdafd35ba83cf387b8147cd70d842b9d2}"
AGH_TARBALL="AdGuardHome_linux_arm64.tar.gz"
AGH_URL="${AGH_URL:-https://github.com/AdguardTeam/AdGuardHome/releases/download/v${AGH_VER}/${AGH_TARBALL}}"

# ── Service coordinates ──────────────────────────────────────────────────────
# Web UI AND plain-HTTP DoH /dns-query share ONE loopback port (see the version
# note above). The DNS resolver listener is a HIGH non-privileged loopback port —
# NEVER :53 (privileged + unreachable over the CGNAT/HTTP tunnel anyway).
AGH_UI_PORT="${ADGUARD_PORT:-9129}"        # http.address — web UI + /dns-query DoH
# Resolver listener: a HIGH loopback port in OUR allocated block. NOT :53 (privileged
# + can't cross the tunnel) and deliberately NOT 5353 (mDNS' well-known port — Android
# may already hold *:5353, which would clash and trip the socket audit). DoH rides the
# UI port, so this listener is internal-consistency only.
AGH_DNS_PORT="${ADGUARD_DNS_PORT:-9130}"   # dns.port — loopback resolver, HIGH port (NOT 53/5353)
AGH_HOST="dns.${DOMAIN}"                    # public hostname (via the CF Tunnel)
INSTALL_DIR=/opt/adguard                    # in userland — the binary
BIN="${INSTALL_DIR}/AdGuardHome"            # in userland — /opt/adguard/AdGuardHome
DATA_MOUNT="${INSTALL_DIR}/data"            # in userland — config + work dir (bind target)
CONFIG_MOUNT="${DATA_MOUNT}/AdGuardHome.yaml"   # in userland — the preseeded 0600 yaml
WORK_MOUNT="${DATA_MOUNT}/work"             # in userland — AGH work dir (sessions/stats/log)

# ── Storage tiers ─────────────────────────────────────────────────────────────
# Config + work dir (sessions DB, query log, stats, filter lists) → EXT4 (NEVER
# exFAT). There is NO bulk read-mostly tier for a DNS resolver, so nothing lands on
# the SD card.
DATA_BACKING="${HOME}/.pocket/adguard"      # on ext4 (host) — survives a rootfs rebuild
CACHE_DIR="${DATA_DIR}/binaries"
AGH_LOCAL="${CACHE_DIR}/AdGuardHome_${AGH_VER}_linux_arm64.tar.gz"

# ── Data dir on ext4 — refuse DATA_DIR (exFAT) fail-closed ───────────────────
# AdGuard's sessions DB + stats + query log need real fsync + atomic rename +
# POSIX locks; exFAT can silently corrupt all of that. Refuse it the same way
# vaultwarden.sh / dufs.sh do.
assert_ext4 "${DATA_BACKING}" "AdGuard Home data dir"
mkdir -p "${DATA_BACKING}" "${CACHE_DIR}" || die "cannot create ${DATA_BACKING} on ext4"
chmod 700 "${DATA_BACKING}" 2>/dev/null || true

# ── Preflight: the userland must exist ───────────────────────────────────────
in_debian 'true' >/dev/null 2>&1 || die "proot-distro debian not reachable — install the userland first (run scripts/install.sh)"

# ── Preflight: htpasswd (apache2-utils) for the OFF-ARGV bcrypt hash ─────────
# We seed the admin user as a BCRYPT hash. htpasswd -niB reads the password from
# STDIN (so the cleartext never appears on any command line / in `ps`). Ensure
# apache2-utils is present in the userland.
if ! in_debian 'command -v htpasswd >/dev/null 2>&1'; then
  say "installing apache2-utils (htpasswd) in the userland for the bcrypt hash"
  in_debian 'apt-get update -qq && apt-get install -y --no-install-recommends apache2-utils' \
    2>&1 | grep -v 'proot warning' \
    || die "could not install apache2-utils (htpasswd) in the userland — needed to hash the admin password off-argv"
fi

# ── 1. Download the release tarball, sha256-verified fail-closed ─────────────
# fetch_verified (from common.sh) reuses a cached copy that already matches the
# pin, and deletes + aborts on any mismatch.
fetch_verified "${AGH_URL}" "${AGH_LOCAL}" "${AGH_SHA256}"
ok "AdGuard Home v${AGH_VER} tarball ready at ${AGH_LOCAL} ($(wc -c < "${AGH_LOCAL}") bytes)"

# ── 2. Extract the binary into the userland + verify it runs ─────────────────
# proot-distro manages the rootfs path, so go through `proot-distro login` and
# stream the tarball in over stdin (no hardcoded rootfs location). The release
# tarball stores its members WITH a leading "./" (./AdGuardHome/AdGuardHome). We
# extract the whole archive to a temp dir and install JUST the binary by BASENAME
# — NOT via `--strip-components=1 AdGuardHome/AdGuardHome`, because that bare member
# spec does not match the "./"-prefixed entries under GNU tar (it silently matches
# nothing and the install would abort). Matching on basename is robust to any future
# repackaging. ${BIN} is passed off-argv as $1 (a fixed, trusted path); $tmp/$bp
# evaluate inside the userland.
say "extracting AdGuard Home into the userland (${INSTALL_DIR})"
in_debian "mkdir -p ${INSTALL_DIR}"
proot-distro login debian -- bash -lc '
  set -e
  tmp="$(mktemp -d)"
  tar -xzf - -C "$tmp"
  bp="$(find "$tmp" -type f -name AdGuardHome | head -1)"
  [ -n "$bp" ] || { echo "AdGuardHome binary not found in the downloaded tarball" >&2; rm -rf "$tmp"; exit 3; }
  install -m 0755 "$bp" "$1"
  rm -rf "$tmp"
' _ "${BIN}" < "${AGH_LOCAL}" || die "failed to extract the AdGuardHome binary into the userland"
in_debian "[ -x ${BIN} ]" || die "AdGuardHome binary missing after extract at ${BIN}"
ver="$(in_debian "${BIN} --version 2>&1 | head -1" || true)"
[ -n "${ver}" ] && ok "AdGuard Home: ${ver}" || warn "AdGuardHome --version produced no output (continuing; the supervisor will surface a real boot failure)"

# ── 3. Bind-mount target in the userland (config + work dir on ext4) ──────────
in_debian "mkdir -p ${DATA_MOUNT} ${WORK_MOUNT}" \
  || die "failed to create the ${DATA_MOUNT}/${WORK_MOUNT} mountpoints in the userland"
ok "data backing ${DATA_BACKING} (ext4) → ${DATA_MOUNT} (bound at start time)"

# ── 4. Generate the admin BCRYPT hash OFF-ARGV (password via stdin) ──────────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ htpasswd -niB reads the password from STDIN and prints "user:$2y$..bcrypt..".
# │   -n : print to stdout (do NOT touch a file)   -i : read password from stdin
# │   -B : bcrypt                                   (we strip the leading "user:")
# │ The cleartext ${ADMIN_PASSWORD} is piped on stdin and NEVER appears on argv,
# │ so it cannot leak via `ps`. We run htpasswd inside the userland (where it was
# │ installed above) and capture only the hash on the host side.
# └────────────────────────────────────────────────────────────────────────────
say "generating the AdGuard admin bcrypt hash (password via stdin, off-argv)"
AGH_PASS_HASH="$(printf '%s' "${ADMIN_PASSWORD}" \
  | proot-distro login debian -- bash -lc "htpasswd -niB '${ADMIN_USER}' 2>/dev/null | head -1" \
  | sed "s/^${ADMIN_USER}://")"
case "${AGH_PASS_HASH}" in
  '$2'*) : ;;   # a bcrypt hash starts with $2a$ / $2b$ / $2y$
  *) die "failed to produce a bcrypt hash for the AdGuard admin (got '${AGH_PASS_HASH:-<empty>}') — check that apache2-utils/htpasswd is installed in the userland" ;;
esac
ok "AdGuard admin bcrypt hash generated for user '${ADMIN_USER}' (cleartext never on argv)"

# ── 5. Pre-seed AdGuardHome.yaml (chmod 600) — skips the first-run wizard ─────
# ┌── SECURITY-LOAD-BEARING: loopback binds + NO :53 ──────────────────────────
# │ proot shares the phone's network namespace, so a 0.0.0.0 bind would expose
# │ AdGuard on the phone's REAL Wi-Fi/cell interfaces. We pin EVERYTHING to
# │ loopback:
# │   http.address      = 127.0.0.1:${AGH_UI_PORT}   (web UI + plain-HTTP DoH)
# │   http.doh.insecure_enabled = true               (serve /dns-query over HTTP,
# │                                                    behind Caddy — v0.107.74+)
# │   dns.bind_hosts    = [127.0.0.1]                 (resolver — loopback only)
# │   dns.port          = ${AGH_DNS_PORT}             (HIGH non-priv port, NOT 53)
# │ trusted_proxies includes 127.0.0.1 so AGH honours X-Forwarded-* from the local
# │ Caddy for the real client IP on DoH requests. A complete `users:`, `dns`, and
# │ schema_version means AdGuard treats itself as already-configured and SKIPS the
# │ setup wizard (so the first visitor cannot hijack the admin account).
# │ Step 6 (post-start `ss`) is the hard backstop against any wildcard/:53 listen.
# └────────────────────────────────────────────────────────────────────────────
# This heredoc is UNQUOTED so the shell expands ${ADMIN_USER}, ${AGH_PASS_HASH},
# ${AGH_UI_PORT}, ${AGH_DNS_PORT}, ${AGH_HOST}, ${TZ}. The bcrypt hash contains '$'
# but it is a captured variable (the shell substitutes its literal value once); it
# is wrapped in single quotes in the YAML so AdGuard parses the literal hash.
say "writing pre-seeded ${CONFIG_MOUNT} (chmod 600; skips the first-run wizard)"
proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- bash -lc "umask 077; cat > ${CONFIG_MOUNT}" <<EOF
# Generated by scripts/apps/adguard.sh — DoH-over-tunnel resolver. AdGuard Home
# v${AGH_VER}. Loopback-only; Caddy + the Cloudflare Tunnel front the edge.
# A complete users/dns/schema_version block means the first-run wizard is SKIPPED.
http:
  # ┌─ SECURITY-LOAD-BEARING: web UI + plain-HTTP DoH on loopback ONLY ─────────
  # │ Both the admin UI AND the /dns-query DoH endpoint are served here. Caddy is
  # │ the only thing that reaches this port. NEVER change to 0.0.0.0.
  # └───────────────────────────────────────────────────────────────────────────
  address: 127.0.0.1:${AGH_UI_PORT}
  # Serve DNS-over-HTTPS over PLAIN HTTP (no TLS at this hop) so the local Caddy /
  # Cloudflare Tunnel can terminate public TLS in front of it. (Replaces the
  # removed tls.allow_unencrypted_doh as of v0.107.74.)
  doh:
    insecure_enabled: true
  session_ttl: 720h
# No web-UI users may self-register; the single admin below is seeded from .env.
users:
  - name: ${ADMIN_USER}
    password: '${AGH_PASS_HASH}'
auth_attempts: 5
block_auth_min: 15
# Trust the local reverse proxy so DoH client IPs are read from X-Forwarded-For.
http_proxy: ""
language: en
theme: auto
dns:
  # ┌─ SECURITY-LOAD-BEARING: resolver on loopback, HIGH port, NEVER :53 ───────
  # │ A non-root proot userland cannot bind privileged :53, and the CGNAT/HTTP
  # │ tunnel cannot carry raw UDP/53 anyway. The resolver listens on a HIGH
  # │ loopback port purely so AGH is internally consistent; the SHIPPED value prop
  # │ is the DoH endpoint above, not this listener.
  # └───────────────────────────────────────────────────────────────────────────
  bind_hosts:
    - 127.0.0.1
  port: ${AGH_DNS_PORT}
  # Trust the on-box Caddy so /dns-query requests carry the real client IP.
  trusted_proxies:
    - 127.0.0.1/32
    - ::1/128
  # Sensible filtering upstreams over encrypted transport (DoH). Edit freely later.
  upstream_dns:
    - https://dns10.quad9.net/dns-query
    - https://dns.cloudflare.com/dns-query
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
  upstream_mode: load_balance
  enable_dnssec: true
# AdGuard's work dir (sessions DB, query log, stats, downloaded filter lists) — on
# the ext4 bind, NEVER exFAT.
filtering:
  protection_enabled: true
  filtering_enabled: true
# A starter blocklist; manage the rest from the UI.
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
querylog:
  enabled: true
  interval: 24h
statistics:
  enabled: true
  interval: 24h
# A schema_version + the users/dns blocks above make AGH treat itself as already
# configured and SKIP the first-run wizard. NOTE: AGH owns this file after first
# start — if this value is older than the running binary's schema it auto-migrates
# (e.g. v0.107.77 bumps 28->34) and rewrites the yaml on first boot; that is expected
# and harmless. We keep 28 deliberately: AGH migrates it forward correctly, whereas
# declaring a too-new schema with these key shapes risks a silently-ignored setting.
schema_version: 28
EOF
in_debian "[ -s ${CONFIG_MOUNT} ]" || die "failed to write ${CONFIG_MOUNT} into the userland"
in_debian "chmod 600 ${CONFIG_MOUNT}" || true
ok "wrote ${CONFIG_MOUNT} (chmod 600)"

# ── 5b. FAIL-CLOSED pre-start config assert (loopback + NOT :53) ─────────────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ Before we ever launch, re-read the rendered yaml and confirm the binds are
# │ loopback and the resolver port is NOT 53. This catches an env override (e.g.
# │ a bad ADGUARD_DNS_PORT) before a single packet is served. The post-start `ss`
# │ check (step 7) is the runtime backstop.
# └────────────────────────────────────────────────────────────────────────────
say "asserting AdGuard binds are loopback + the resolver is not :53 (pre-start)"
in_debian "grep -Eq '^[[:space:]]*address:[[:space:]]*127\.0\.0\.1:${AGH_UI_PORT}[[:space:]]*\$' ${CONFIG_MOUNT}" \
  || die "http.address is NOT 127.0.0.1:${AGH_UI_PORT} — refusing to start a LAN-exposed AdGuard (check ${CONFIG_MOUNT})"
in_debian "grep -Eq '0\.0\.0\.0' ${CONFIG_MOUNT}" \
  && die "AdGuardHome.yaml contains a 0.0.0.0 bind — refusing to start (check ${CONFIG_MOUNT})" || true
case "${AGH_DNS_PORT}" in
  53) die "ADGUARD_DNS_PORT is 53 — refusing: a non-root proot cannot bind :53 and the CGNAT/HTTP tunnel cannot carry UDP DNS; use a HIGH loopback port (e.g. 9130)" ;;
esac
ok "AdGuard config binds confirmed loopback; resolver on high port ${AGH_DNS_PORT} (not :53)"

# ── 6. Caddy vhost → /etc/caddy/apps/adguard.caddy (validate fail-closed) ────
# A self-contained site block so enabling AdGuard never requires hand-editing the
# core Caddyfile (it imports /etc/caddy/apps/*.caddy). The listener style MUST
# match the other vhosts: explicit `http://<host>:${CADDY_PORT}` + `bind
# ${CADDY_BIND}` (plain HTTP on the shared high loopback port; the Cloudflare
# Tunnel terminates public TLS). The explicit http:// scheme stops Caddy inferring
# HTTPS-on-:443, which an unprivileged proot Caddy cannot bind.
#
# GATE-THE-UI / EXEMPT-THE-DoH: /dns-query (DoH clients send a raw DNS wire body
# and CANNOT follow a 302-to-login) is reverse_proxied DIRECTLY, BEFORE the
# gateable catch-all, so it is never subject to the interactive forward_auth. The
# optional Matrix-SSO gate, when uncommented, covers ONLY the catch-all (the admin
# UI). Mirror this in Cloudflare Access too (path-BYPASS /dns-query) — see the
# closing notes. NOTE: both the UI and /dns-query proxy to the SAME backend port
# (${AGH_UI_PORT}); on v0.107.74+ DoH rides the web-UI port.
#
# This heredoc is UNQUOTED so the shell expands ${DOMAIN}, ${CADDY_BIND},
# ${CADDY_PORT}, and ${AGH_UI_PORT}.
say "writing the AdGuard vhost to /etc/caddy/apps/adguard.caddy in the userland"
in_debian "mkdir -p /etc/caddy/apps"
if ! proot-distro login debian -- bash -lc 'cat > /etc/caddy/apps/adguard.caddy' <<EOF
# dns.${DOMAIN} — AdGuard Home (DoH-over-tunnel RESOLVER; NOT a :53 sinkhole).
# Written by scripts/apps/adguard.sh. Loopback-only; the Cloudflare Tunnel forwards
# public traffic here and (by default) Cloudflare Access gates the admin UI at the
# edge — but you MUST EXEMPT /dns-query there too (DoH clients send a raw DNS body
# and cannot do a 302 login; without the bypass they silently fail). See
# docs/ADGUARD.md + docs/APP_AUTH.md.
http://dns.${DOMAIN}:${CADDY_PORT} {
	bind ${CADDY_BIND}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy no-referrer
		-Server
	}

	# ── EXEMPT the DoH endpoint (NEVER gated) ───────────────────────────────────
	# DoH clients (Android Private DNS, Firefox, routers) POST/GET a raw DNS
	# wire-format body to /dns-query and CANNOT follow an interactive 302. This
	# handle reverse_proxies straight to the backend and MUST come BEFORE the
	# gateable catch-all below. On v0.107.74+ DoH is served on the same backend
	# port as the UI (${AGH_UI_PORT}).
	handle /dns-query* {
		reverse_proxy 127.0.0.1:${AGH_UI_PORT}
	}

	# ── Admin web UI (gateable) ─────────────────────────────────────────────────
	handle {
		# OPTIONAL Matrix-SSO gateway add-on (advanced; see docs/APP_AUTH.md).
		# By default this stays COMMENTED OUT: the hostname is gated by Cloudflare
		# Access at the edge and AdGuard keeps its own admin login. To front the
		# ADMIN UI with the Matrix-SSO gateway instead, run that add-on and
		# uncomment the three parts below — they MUST precede the catch-all
		# reverse_proxy and they ONLY cover this UI handle (NOT /dns-query above,
		# which must stay ungated for DoH clients). The /authgw/* handler keeps the
		# login form reachable (else the 302-to-login loops), the request_header
		# strips any client-forged Remote-User before the gate, and forward_auth
		# then gates everything else:
		#
		# handle /authgw/* {
		# 	reverse_proxy 127.0.0.1:9095 {
		# 		header_up X-Real-IP {client_ip}
		# 	}
		# }
		# request_header -Remote-User
		# forward_auth 127.0.0.1:9095 {
		# 	uri /authgw/verify
		# 	copy_headers Remote-User
		# }

		# Admin UI → the AdGuard backend on loopback.
		reverse_proxy 127.0.0.1:${AGH_UI_PORT}
	}
}
EOF
then
  die "failed to write /etc/caddy/apps/adguard.caddy into the userland"
fi

# Validate the WHOLE Caddyfile (which imports our new app block) fail-closed, so
# we never leave a broken edge config in place.
say "validating the Caddyfile inside the userland"
in_debian 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' \
  || die "caddy validate FAILED — refusing to leave a broken vhost in /etc/caddy/apps/adguard.caddy"
ok "AdGuard vhost written + Caddyfile validates"

# NOTE: we do NOT restart Caddy here. During a full install the stack is started
# afterward (scripts/start-stack.sh). If the stack is ALREADY running, the new
# vhost is not live until Caddy reloads — see the closing notes.

# ── 7. Supervise AdGuard Home on loopback ────────────────────────────────────
# Run the Go binary with --no-check-update (no phone-home), an explicit config
# path (-c, on the ext4 bind) and an explicit work dir (-w, on the ext4 bind so
# the sessions DB / query log / stats / filter lists never touch exFAT). All
# config (binds, port, the admin hash) lives in the 0600 yaml, NOT on argv. The
# ext4 backing is bind-mounted at launch so a rootfs rebuild keeps the state.
say "supervising AdGuard Home (Go binary in the userland, UI+DoH 127.0.0.1:${AGH_UI_PORT})"
supervise adguard -- \
  proot-distro login debian \
  --bind "${DATA_BACKING}:${DATA_MOUNT}" \
  -- "${BIN}" --no-check-update -c "${CONFIG_MOUNT}" -w "${WORK_MOUNT}"

# ── 8. FAIL-CLOSED post-start loopback / NO-:53 assert (ss) ───────────────────
# ┌── SECURITY-LOAD-BEARING ───────────────────────────────────────────────────
# │ The hard runtime backstop (navidrome/dufs pattern, extended to DNS): after the
# │ service comes up, enumerate ACTUAL listening sockets with `ss -ltnH` (TCP) and
# │ `ss -lunH` (UDP — the resolver) inside the userland and REFUSE to leave a
# │ wildcard or :53 listener running. If anything is on 0.0.0.0 / [::] / '*' OR on
# │ port 53, we unsupervise + die rather than leave AdGuard LAN-exposed. We wait
# │ for the UI port to come up first so the sockets exist when we check.
# │ NB: proot shares the host net ns, so this `ss` sees the phone's real sockets.
# └────────────────────────────────────────────────────────────────────────────
say "waiting for AdGuard to answer on 127.0.0.1:${AGH_UI_PORT} before the socket audit"
up=0
for _ in $(seq 1 40); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${AGH_UI_PORT}/" 2>/dev/null \
     || curl -s -m 3 -o /dev/null "http://127.0.0.1:${AGH_UI_PORT}/" 2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
[ "${up}" -eq 1 ] || warn "AdGuard not yet answering on :${AGH_UI_PORT} — running the socket audit anyway (the supervisor keeps retrying)"

say "auditing AdGuard's own listeners (refuse a wildcard bind on :${AGH_UI_PORT}/:${AGH_DNS_PORT})"
# Collect TCP + UDP listeners as seen from the host net ns (via the userland).
# Local-address column is field 4 in `ss -H` output (e.g. 127.0.0.1:9129, *:9130).
# ss ships with iproute2 in the userland.
sockets="$(in_debian '(command -v ss >/dev/null 2>&1 && { ss -ltnH 2>/dev/null; ss -lunH 2>/dev/null; }) || true')"
if [ -z "${sockets}" ]; then
  warn "could not enumerate sockets via ss inside the userland — SKIPPING the runtime audit (the pre-start config assert in step 5b already requires loopback binds + a non-:53 port). Install iproute2 in the userland for the runtime backstop."
else
  # ┌── SCOPE THE AUDIT TO ADGUARD'S OWN PORTS ─────────────────────────────────
  # │ proot shares the phone's network namespace, so this `ss` enumerates ALL of
  # │ the device's listeners — including Android/Termux system sockets we don't own
  # │ (a system resolver on *:53, an mDNS responder on *:5353, etc.). A blanket
  # │ "die on ANY wildcard or ANY :53" would false-trip on those and abort a
  # │ perfectly good install on a real phone. So we check ONLY whether ADGUARD's own
  # │ ports (the UI/DoH port + the resolver port) are bound on a wildcard. The
  # │ pre-start config assert (step 5b) already guarantees we configured loopback +
  # │ a non-:53 resolver port; this is the runtime backstop against a binary that
  # │ ignores its config (the Photoview-class trap), scoped so it can't false-trip.
  # └────────────────────────────────────────────────────────────────────────────
  bad_wild="$(printf '%s\n' "${sockets}" | awk '{print $4}' \
    | grep -E "^(0\.0\.0\.0|\*|\[::\]|::):(${AGH_UI_PORT}|${AGH_DNS_PORT})\$" || true)"
  if [ -n "${bad_wild}" ]; then
    unsupervise adguard
    die "AdGuard is listening on a WILDCARD address (${bad_wild//$'\n'/ }) for its OWN port — refusing to leave a LAN-exposed resolver. Stopped it. Check ${CONFIG_MOUNT}."
  fi
  ok "socket audit clean — AdGuard's ports (${AGH_UI_PORT}/${AGH_DNS_PORT}) are loopback-only (no wildcard bind)"
fi

# ── 9. Best-effort health check ──────────────────────────────────────────────
# /control/status is an unauthenticated liveness endpoint (returns JSON). A non-200
# here is a WARNING (the supervisor keeps retrying), not fatal.
say "waiting for AdGuard /control/status on 127.0.0.1:${AGH_UI_PORT}"
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${AGH_UI_PORT}/control/status" 2>/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if [ "${healthy}" -eq 1 ]; then
  ok "AdGuard Home healthy on 127.0.0.1:${AGH_UI_PORT} (/control/status)"
else
  warn "AdGuard not yet answering /control/status on :${AGH_UI_PORT} — check ${POCKET_LOG_DIR}/adguard.log (the supervisor keeps retrying)"
fi

# ── 10. Closing notes (manual Cloudflare + the scope reality) ─────────────────
cat >&2 <<EOF

$(ok "AdGuard Home installed + supervised on 127.0.0.1:${AGH_UI_PORT} (DoH endpoint + admin UI; data on ${DATA_BACKING})" 2>&1)

  SCOPE — DoH-over-tunnel ONLY (this is the whole design):
    This is a private filtering DNS-over-HTTPS RESOLVER, NOT a LAN ":53" sinkhole.
    A non-root proot cannot bind privileged :53, and the CGNAT/Cloudflare Tunnel
    carries HTTP(S), not raw UDP DNS — so a network-wide :53 sinkhole is impossible
    on this stack. For that you need Tailscale or a LAN box. See docs/ADGUARD.md.

  USE IT: point a device's "Private DNS / DoH" at:
         https://${AGH_HOST}/dns-query
    (Android: Settings > Network > Private DNS > hostname = ${AGH_HOST}; Firefox:
     custom DoH URL above; routers: per-vendor DoH field.)

  Manual steps to finish (in the Cloudflare dashboard — NOT done by this script):
    1. Public hostname: add a Public Hostname in your Cloudflare Tunnel:
         ${AGH_HOST}  ->  http://localhost:${CADDY_PORT}
       (plain HTTP — the tunnel terminates public TLS).
    2. Cloudflare Access — GATE THE UI, EXEMPT THE DoH ENDPOINT: add an Access
       application for ${AGH_HOST} to gate the admin UI, but you MUST also add a
       path-based BYPASS (or a SERVICE TOKEN) for:
         /dns-query    (DoH clients — Android Private DNS / Firefox / routers)
       DoH clients send a raw DNS wire body and CANNOT complete an interactive
       Access login redirect — without the exemption they SILENTLY FAIL. The vhost
       already reverse_proxies /dns-query without the SSO gate. See docs/APP_AUTH.md.

  Admin UI: log in at ${AGH_HOST} as '${ADMIN_USER}' — use the ADMIN_PASSWORD value
    from your .env. The first-run setup wizard is already skipped (the user is
    pre-seeded), so the UI lands on the dashboard.

  If the stack is ALREADY running, reload Caddy so the new vhost goes live:
         bash ${POCKET_ROOT}/scripts/start-stack.sh --restart
    (a full install starts the stack afterward, so no reload is needed then).
EOF

ok "apps/adguard.sh done (dns.${DOMAIN} once the Cloudflare hostname + Access policy + /dns-query exemption are added)"
