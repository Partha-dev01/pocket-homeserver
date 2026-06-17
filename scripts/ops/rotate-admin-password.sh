#!/usr/bin/env bash
#
# ops/rotate-admin-password.sh — rotate the WEB ADMIN PANEL login password.
#
# Generates a new random password, scrypt-hashes it with the exact parameters the
# panel verifies against (n=2^14, r=8, p=1, dklen=32; stored as "salthex:hashhex"),
# and writes ${DATA_DIR}/secrets/adminweb-password.hash (0600). The panel re-reads
# that file on every login, so the change is effective immediately — no restart.
#
# The new password is printed ONCE to stdout (the admin panel shows it on the
# confirmation result page). Save it now; it is not stored anywhere in plaintext.
# Your CURRENT panel session stays signed in; new logins need the new password.
#
# NOTE: this rotates the panel's own login only. (Rotating a Matrix admin user's
# password is a separate, future action — see docs/ADMIN.md.)
#
# Generalized from a working deployment; review before running on a fresh phone.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

load_env
require_var DATA_DIR "folder on your large volume / SD card"
require_cmd python3

SECRETS_DIR="${DATA_DIR}/secrets"
HASH_FILE="${SECRETS_DIR}/adminweb-password.hash"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}" 2>/dev/null || true

# Everything sensitive happens inside python3: the password is generated, hashed,
# and the 0600 hash file written there, then ONLY the new password is printed to
# stdout — the plaintext never appears on any command line or in a shell variable.
NEW_PASS="$(python3 - "${HASH_FILE}" <<'PY'
import os, sys, secrets, string, hashlib
hash_file = sys.argv[1]
alphabet = string.ascii_letters + string.digits
pw = "".join(secrets.choice(alphabet) for _ in range(24))
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
fd = os.open(hash_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.write(fd, (salt.hex() + ":" + digest.hex()).encode())
finally:
    os.close(fd)
print(pw)
PY
)"

[ -n "${NEW_PASS}" ] || die "password generation failed"
[ -s "${HASH_FILE}" ] || die "password hash was not written to ${HASH_FILE}"
chmod 600 "${HASH_FILE}" 2>/dev/null || true

ok "admin panel password rotated"
echo
echo "  new admin password:  ${NEW_PASS}"
echo
echo "SAVE THIS NOW — it is not stored in plaintext anywhere."
echo "Your current session stays signed in; use the new password next time you log in."
