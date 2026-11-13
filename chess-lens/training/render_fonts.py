"""Adds piece sets drawn from fonts that carry the Unicode chess symbols (U+2654..U+265F).

Printed diagrams are set in figurine fonts, so these are close to what books look like. White
pieces in a font are outlines; a second variant fills their interior with white, as on a screen.

    python3 training/render_fonts.py <outDir> [font.ttf ...]
"""

import os
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SIZE = 128
NAMES = ["wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP"]


def glyph(font, ch):
    img = Image.new("L", (SIZE * 2, SIZE * 2), 0)
    draw = ImageDraw.Draw(img)
    draw.text((SIZE, SIZE), ch, font=font, fill=255, anchor="mm")
    a = np.array(img)
    ys, xs = np.nonzero(a > 16)
    if len(xs) == 0:
        return None
    a = a[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
    h, w = a.shape
    scale = (SIZE * 0.84) / max(h, w)
    a = cv2.resize(a, (max(1, round(w * scale)), max(1, round(h * scale))), interpolation=cv2.INTER_AREA)
    out = np.zeros((SIZE, SIZE), np.uint8)
    y0 = SIZE - 8 - a.shape[0]  # sit on a common baseline
    x0 = (SIZE - a.shape[1]) // 2
    out[y0 : y0 + a.shape[0], x0 : x0 + a.shape[1]] = a
    return out


def to_rgba(ink, fill=None):
    """ink: stroke alpha. fill: optional interior mask painted white under the strokes."""
    rgba = np.zeros((SIZE, SIZE, 4), np.uint8)
    if fill is not None:
        rgba[..., :3] = 255
        rgba[..., 3] = fill
    a = ink.astype(np.float32) / 255
    for c in range(3):
        rgba[..., c] = (rgba[..., c] * (1 - a)).astype(np.uint8)
    rgba[..., 3] = np.maximum(rgba[..., 3], ink)
    return rgba


def interior(ink):
    """Everything enclosed by the strokes (the piece's silhouette)."""
    solid = (ink > 96).astype(np.uint8)
    flood = solid.copy()
    mask = np.zeros((SIZE + 2, SIZE + 2), np.uint8)
    cv2.floodFill(flood, mask, (0, 0), 2)
    return np.where(flood == 2, 0, 255).astype(np.uint8)


def main():
    out = sys.argv[1]
    fonts = sys.argv[2:]
    if not fonts:
        listed = subprocess.run(["fc-list", ":charset=2654:scalable=true", "file"], capture_output=True, text=True).stdout
        fonts = sorted({line.split(":")[0] for line in listed.splitlines() if line.strip()})
    made = []
    for path in fonts:
        try:
            font = ImageFont.truetype(path, 150)
        except OSError:
            continue
        glyphs = [glyph(font, chr(0x2654 + i)) for i in range(12)]
        if any(g is None for g in glyphs):
            continue
        base = "font-" + os.path.splitext(os.path.basename(path))[0].lower()
        for variant in ("outline", "filled"):
            d = os.path.join(out, f"{base}-{variant}")
            os.makedirs(d, exist_ok=True)
            for name, g in zip(NAMES, glyphs):
                white = name[0] == "w"
                rgba = to_rgba(g, interior(g) if (white and variant == "filled") else None)
                Image.fromarray(rgba, "RGBA").save(os.path.join(d, name + ".png"))
            made.append(f"{base}-{variant}")
    print("rendered", made)


if __name__ == "__main__":
    main()
