#!/usr/bin/env python3
"""Generate simple circular avatar PNGs for the bootstrapped Matrix entities.

Produces three neutral, customizable avatars:

  - space.png          a brand-colored letter for the hub Space
  - announcements.png  an orange "!" for the announcements room
  - admin.png          a letter for the admin user

Everything is configurable via the environment so nothing operator-specific is
baked in:

  AVATAR_OUT_DIR      where to write the PNGs (default: ${DATA_DIR}/avatars, or
                      ./avatars if DATA_DIR is unset)
  AVATAR_SPACE_TEXT   glyph/text on the Space avatar      (default: first letter
                      of MATRIX_SPACE_NAME, else "H")
  AVATAR_ADMIN_TEXT   glyph/text on the admin avatar       (default: "A")
  AVATAR_SPACE_BG     Space avatar background hex           (default "#0A7D4F")
  AVATAR_ADMIN_BG     admin avatar background hex           (default "#2D5C7A")
  AVATAR_ANN_BG       announcements avatar background hex    (default "#D9541E")

Requires Pillow:  pip install Pillow   (or: apt-get install python3-pil)

Companion: set-avatars.py uploads these to the homeserver media repo and sets
them on the Space / room / admin user.
"""
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.stderr.write(
        "Pillow is required: pip install Pillow  (or apt-get install python3-pil)\n"
    )
    sys.exit(2)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    # Termux package: fontconfig / dejavu
    "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
]


def _out_dir():
    explicit = os.environ.get("AVATAR_OUT_DIR")
    if explicit:
        return explicit
    data_dir = os.environ.get("DATA_DIR")
    if data_dir:
        return os.path.join(data_dir, "avatars")
    return os.path.join(os.getcwd(), "avatars")


def find_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def make_circle_avatar(text, bg, fg="#FFFFFF", size=512, out="out.png"):
    img = Image.new("RGB", (size, size), bg)
    draw = ImageDraw.Draw(img)
    draw.ellipse((0, 0, size, size), fill=bg)
    font_size = int(size * (0.55 if len(text) == 1 else 0.32))
    font = find_font(font_size)
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (size - tw) // 2 - bbox[0]
    y = (size - th) // 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=fg)
    img.save(out, "PNG", optimize=True)
    print(f"  {out}  ({os.path.getsize(out)} bytes)")


def main():
    out_dir = _out_dir()
    os.makedirs(out_dir, exist_ok=True)

    space_name = os.environ.get("MATRIX_SPACE_NAME", "Hub")
    space_text = os.environ.get("AVATAR_SPACE_TEXT") or (space_name[:1].upper() or "H")
    admin_text = os.environ.get("AVATAR_ADMIN_TEXT", "A")

    space_bg = os.environ.get("AVATAR_SPACE_BG", "#0A7D4F")
    admin_bg = os.environ.get("AVATAR_ADMIN_BG", "#2D5C7A")
    ann_bg = os.environ.get("AVATAR_ANN_BG", "#D9541E")

    print(f"generating avatars into {out_dir}")
    make_circle_avatar(space_text, space_bg, out=os.path.join(out_dir, "space.png"))
    make_circle_avatar("!", ann_bg, out=os.path.join(out_dir, "announcements.png"))
    make_circle_avatar(admin_text, admin_bg, out=os.path.join(out_dir, "admin.png"))
    print("done")


if __name__ == "__main__":
    main()
