#!/usr/bin/env python3
"""r2-check.py — list objects in the R2 mail bucket (verification helper).

Reuses mail-drain.py's stdlib SigV4 signer (no boto3). Reads R2_* from the
environment, so source the secrets env first, e.g.:

    set -a; . "${DATA_DIR}/secrets/mail-r2.env"; set +a
    python3 r2-check.py [prefix ...]            # default: pending/ processed/

Prints only object keys/sizes/timestamps — never the credentials.
"""
import os, sys, importlib.util
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("maildrain", os.path.join(HERE, "mail-drain.py"))
md = importlib.util.module_from_spec(spec)
spec.loader.exec_module(md)  # reads R2_* from env at import; main() guarded by __main__


def list_prefix(prefix):
    out, tok = [], None
    while True:
        q = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
        if tok:
            q["continuation-token"] = tok
        # s3_request returns (status, body, headers); we only need the body here.
        _, body, _ = md.s3_request("GET", "", query=q)
        root = ET.fromstring(body)
        for c in root.findall(f"{md.S3NS}Contents"):
            out.append((c.findtext(f"{md.S3NS}Key"),
                        c.findtext(f"{md.S3NS}Size"),
                        c.findtext(f"{md.S3NS}LastModified")))
        if (root.findtext(f"{md.S3NS}IsTruncated") or "false") == "true":
            tok = root.findtext(f"{md.S3NS}NextContinuationToken")
        else:
            break
    return out


def main():
    prefixes = sys.argv[1:] or ["pending/", "processed/"]
    for pfx in prefixes:
        try:
            items = list_prefix(pfx)
        except Exception as e:
            print(f"== {pfx} : ERROR {type(e).__name__}: {e}")
            continue
        print(f"== {pfx} : {len(items)} object(s) ==")
        for k, sz, lm in items:
            print(f"   {k}   {sz}B   {lm}")


if __name__ == "__main__":
    main()
