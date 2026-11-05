#!/usr/bin/env python3
"""Backlight.png (1024 x 1024: the whole icon with its margin and shadow) -> Backlight.icns, small.

iconutil re-encodes every picture as plain 32-bit PNG (1.4 MB for this icon, a quarter of the app), so the
file is written here instead: the same PNG chunks an .icns takes, with the large sizes reduced to a 256-colour
palette with ordered dithering (the soft glow stays smooth to the eye) and no 1024 px picture (macOS scales the
512 px one). Needs sips and ImageMagick (`magick`); the result is kept in the repository, so only whoever
changes the icon needs either.
"""
import os, struct, subprocess, tempfile

here = os.path.dirname(os.path.abspath(__file__))
source = os.path.join(here, "Backlight.png")
# type, pixels
chunks = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512)]
palette_from = 128

with tempfile.TemporaryDirectory() as work:
    made = {}
    for _, px in chunks:
        if px in made:
            continue
        out = os.path.join(work, f"{px}.png")
        subprocess.run(["sips", "-z", str(px), str(px), source, "--out", out], check=True, capture_output=True)
        if px >= palette_from:
            subprocess.run(["magick", out, "-strip", "-ordered-dither", "o4x4,32", "-colors", "256", "-define", "png:compression-level=9", out], check=True)
        made[px] = open(out, "rb").read()
    body = b"".join(kind.encode() + struct.pack(">I", 8 + len(made[px])) + made[px] for kind, px in chunks)
    with open(os.path.join(here, "Backlight.icns"), "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
print("wrote icon/Backlight.icns", 8 + len(body), "bytes")
