#!/usr/bin/env python3
"""Upload the generated PNG avatars to the homeserver and set them on the admin
user, the hub Space, and the announcements room.

Runs TERMUX-NATIVE: it talks to the homeserver over the loopback client-server
and media APIs (http://127.0.0.1:8448). stdlib-only — no third-party deps here
(Pillow is only needed by make-avatars.py to GENERATE the PNGs).

Credentials are read from the 0600 file written by create-admin.sh:
    ${DATA_DIR}/secrets/admin-credentials.env   (ADMIN_TOKEN, ADMIN_MXID, SERVER_NAME)
The token is NEVER taken from argv or the process environment of a child.

Avatars are read from AVATAR_OUT_DIR (default ${DATA_DIR}/avatars), the same dir
make-avatars.py writes to.

Env (all optional; neutral defaults match the other bootstrap helpers):
    MATRIX_HS_API           homeserver base URL (default http://127.0.0.1:8448)
    DATA_DIR                data root; secrets + avatars live under it
    AVATAR_OUT_DIR          override the avatars dir
    MATRIX_SPACE_ALIAS      Space alias localpart        (default "hub")
    MATRIX_ANNOUNCE_ALIAS   announcements alias localpart (default "announcements")
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

HS = os.environ.get("MATRIX_HS_API", "http://127.0.0.1:8448")


def _data_dir():
    d = os.environ.get("DATA_DIR")
    if not d:
        sys.stderr.write("DATA_DIR is not set — source your .env first\n")
        sys.exit(2)
    return d


def _load_creds():
    """Parse the 0600 admin-credentials.env into a dict (KEY=VALUE lines)."""
    path = os.path.join(_data_dir(), "secrets", "admin-credentials.env")
    if not os.path.exists(path):
        sys.stderr.write(
            f"admin credentials missing at {path} — run create-admin.sh first\n"
        )
        sys.exit(2)
    creds = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            creds[k.strip()] = v.strip()
    return creds


# OPERATOR NOTE: ADMIN_TOKEN loaded here is a privileged homeserver access token
# (it can upload media and write room state / the admin profile). Confirm the
# creds file is 0600 and that you accept any reader of it can act as the admin.
_CREDS = _load_creds()
ADMIN_TOKEN = _CREDS.get("ADMIN_TOKEN", "")
ADMIN_MXID = _CREDS.get("ADMIN_MXID", "")
if not ADMIN_TOKEN or not ADMIN_MXID:
    sys.stderr.write("ADMIN_TOKEN / ADMIN_MXID missing from the credentials file\n")
    sys.exit(2)

SERVER = _CREDS.get("SERVER_NAME") or ADMIN_MXID.split(":", 1)[1]


def _req(method, path, token, body=None, content_type="application/json", timeout=30):
    req = urllib.request.Request(
        HS + path,
        data=body,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": content_type},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read() or b"{}")


def upload(png_path, token):
    """POST /_matrix/media/v3/upload — returns the mxc:// content URI."""
    with open(png_path, "rb") as f:
        data = f.read()
    fname = os.path.basename(png_path)
    path = f"/_matrix/media/v3/upload?filename={urllib.parse.quote(fname)}"
    _status, resp = _req("POST", path, token, body=data, content_type="image/png")
    mxc = resp.get("content_uri")
    if not mxc:
        raise RuntimeError(f"upload failed for {png_path}: {resp}")
    return mxc


def set_user_avatar(mxid, mxc, token):
    path = f"/_matrix/client/v3/profile/{urllib.parse.quote(mxid)}/avatar_url"
    return _req("PUT", path, token, body=json.dumps({"url": mxc}).encode())


def set_room_avatar(room_id, mxc, token):
    path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/state/m.room.avatar/"
    body = {"url": mxc, "info": {"mimetype": "image/png"}}
    return _req("PUT", path, token, body=json.dumps(body).encode())


def resolve_alias(alias, token):
    enc = urllib.parse.quote(alias)
    try:
        _status, resp = _req("GET", f"/_matrix/client/v3/directory/room/{enc}", token)
    except urllib.error.HTTPError:
        return None
    return resp.get("room_id")


def main():
    avatar_dir = os.environ.get("AVATAR_OUT_DIR") or os.path.join(_data_dir(), "avatars")
    space_alias = os.environ.get("MATRIX_SPACE_ALIAS", "hub")
    ann_alias = os.environ.get("MATRIX_ANNOUNCE_ALIAS", "announcements")

    space_id = resolve_alias(f"#{space_alias}:{SERVER}", ADMIN_TOKEN)
    ann_id = resolve_alias(f"#{ann_alias}:{SERVER}", ADMIN_TOKEN)

    print(f"server: {SERVER}")
    print(f"admin: {ADMIN_MXID}")
    print(f"#{space_alias}: {space_id}")
    print(f"#{ann_alias}: {ann_id}")

    def _set(png, setter, target, label):
        path = os.path.join(avatar_dir, png)
        if not os.path.exists(path):
            print(f"  skip {label}: {path} not found (run make-avatars.py first)")
            return
        if not target:
            print(f"  skip {label}: target not resolved")
            return
        mxc = upload(path, ADMIN_TOKEN)
        s, r = setter(target, mxc, ADMIN_TOKEN)
        print(f"  {label}: uploaded {mxc} -> HTTP {s} {r}")

    print("\n1. admin user avatar")
    _set("admin.png", set_user_avatar, ADMIN_MXID, "admin user")

    print("\n2. hub Space avatar")
    _set("space.png", set_room_avatar, space_id, f"#{space_alias} space")

    print("\n3. announcements room avatar")
    _set("announcements.png", set_room_avatar, ann_id, f"#{ann_alias} room")

    print("\ndone.")


if __name__ == "__main__":
    main()
