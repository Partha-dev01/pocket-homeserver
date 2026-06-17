#!/usr/bin/env python3
"""
rsa-der-to-jwk.py — read a PKCS#1 (traditional) RSA private key in DER form on
stdin and print a compact {"n","e","d"} JSON on stdout (big integers as decimal
strings). The auth gateway's RS256 realm loads this JSON
(AUTHGW_OIDC_RS_KEY_FILE) to sign id_tokens with pure-stdlib RSA — no third-party
crypto library required either here or in the gateway.

Used by scripts/steps/60-install-auth-gw.sh:

    openssl genrsa 2048 \
      | openssl rsa -outform DER -traditional \
      | python3 rsa-der-to-jwk.py > authgw-rsa.json

A PKCS#1 RSAPrivateKey is a DER SEQUENCE of INTEGERs:
  version(0), n, e, d, p, q, ...   — we need n (modulus), e (pub exp), d (priv exp).
"""
import json
import sys


def read_len(b, i):
    """Read a DER length at offset i; return (length, next_offset)."""
    n = b[i]
    i += 1
    if n < 0x80:                       # short form
        return n, i
    k = n & 0x7f                       # long form: k length-bytes follow
    return int.from_bytes(b[i:i + k], "big"), i + k


def main():
    b = sys.stdin.buffer.read()
    if not b or b[0] != 0x30:          # 0x30 = SEQUENCE
        sys.stderr.write("rsa-der-to-jwk: input is not a DER SEQUENCE\n")
        return 1
    _, i = read_len(b, 1)              # skip the outer SEQUENCE length
    ints = []
    while len(ints) < 4:               # version, n, e, d
        if b[i] != 0x02:               # 0x02 = INTEGER
            sys.stderr.write("rsa-der-to-jwk: expected INTEGER in RSAPrivateKey\n")
            return 1
        i += 1
        length, i = read_len(b, i)
        ints.append(int.from_bytes(b[i:i + length], "big"))
        i += length
    # ints = [version, n, e, d]
    json.dump({"n": str(ints[1]), "e": str(ints[2]), "d": str(ints[3])}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
