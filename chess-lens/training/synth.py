"""Synthetic scenes for training and evaluating the scanner.

Renders random chess positions in many piece sets and board styles, drops them onto a book page or
a screen, then photographs the result: perspective, uneven light, blur, sensor noise, JPEG.

    python3 training/synth.py --pieces <rendered piece dir> --out <dir> --count 2000 --seed 1

Writes scene_XXXXX.png plus labels.jsonl. Each label holds the board outline in image pixels
(top-left, top-right, bottom-right, bottom-left) and the 64-character placement as drawn, row by
row from the top-left square ('.' for empty, FEN letters otherwise).
"""

import argparse
import json
import os

import cv2
import numpy as np

NAMES = ["wP", "wN", "wB", "wR", "wQ", "wK", "bP", "bN", "bB", "bR", "bQ", "bK"]
LETTERS = "PNBRQKpnbrqk"
SQ = 64  # square size of the flat render

# Unusable for recognition: both colours share a glyph, or the glyphs are not chess figurines.
EXCLUDED_SETS = {"disguised", "shapes", "kiwen-suwi"}
# Sets that look like printed book figurines.
PRINT_SETS = ["alpha", "merida", "leipzig", "companion", "chess7", "cburnett", "mpchess", "kosal", "pirouetti"]

THEMES = [
    ((240, 217, 181), (181, 136, 99)),  # lichess brown
    ((222, 227, 230), (140, 162, 173)),  # lichess blue
    ((255, 255, 221), (134, 166, 102)),  # lichess green
    ((238, 238, 210), (118, 150, 86)),  # chess.com green
    ((240, 217, 181), (148, 111, 81)),
    ((220, 220, 220), (171, 171, 171)),
    ((236, 236, 236), (120, 120, 120)),
    ((232, 208, 170), (166, 126, 94)),
    ((159, 144, 176), (125, 74, 141)),
    ((234, 233, 210), (75, 115, 153)),
    ((255, 255, 255), (200, 200, 200)),
    ((230, 230, 230), (100, 130, 160)),
]

WORDS = (
    "the of and a to in is you that it he was for on are as with his they at be this have from or "
    "one had by word but not what all were we when your can said there use an each which she do how "
    "their if will up other about out many then them these so some her would make like him into "
    "Nf3 e4 Qxd5 O-O Rad1 Bb5+ exd5 Kg2 Nc6 h6 g4 Bxf7+ Rxe8# 1.d4 2.c4 15.Qh5 23...Rxf2 White Black "
    "wins mate position diagram move variation attack defence pawn knight bishop rook queen king"
).split()


def load_sets(piece_dir, only=None, exclude=()):
    sets = {}
    for name in sorted(os.listdir(piece_dir)):
        if name in EXCLUDED_SETS or name in exclude:
            continue
        if only and name not in only:
            continue
        imgs = []
        for n in NAMES:
            im = cv2.imread(os.path.join(piece_dir, name, n + ".png"), cv2.IMREAD_UNCHANGED)
            if im is None or im.shape[2] != 4:
                imgs = None
                break
            imgs.append(im.astype(np.float32) / 255.0)
        if imgs:
            sets[name] = imgs
    return sets


def random_placement(rng):
    kind = rng.random()
    if kind < 0.45:
        # Shuffled real material: thin out the starting army and scatter it.
        start = "rnbqkbnrpppppppp" + "." * 32 + "PPPPPPPPRNBQKBNR"
        pieces = [c for c in start if c != "." and (c in "kK" or rng.random() < rng.uniform(0.3, 1.0))]
        cells = ["."] * 64
        for c, sq in zip(pieces, rng.permutation(64)):
            cells[sq] = c
        return "".join(cells)
    if kind < 0.6:
        # Near the starting position, with a few pieces moved.
        cells = list("rnbqkbnrpppppppp" + "." * 32 + "PPPPPPPPRNBQKBNR")
        for _ in range(rng.integers(0, 14)):
            a, b = rng.integers(0, 64, size=2)
            cells[b] = cells[a]
            cells[a] = "."
        if rng.random() < 0.5:
            cells = cells[::-1]
        return "".join(cells)
    # Uniform over pieces so that every class is well represented.
    p_empty = rng.uniform(0.2, 0.7)
    cells = []
    for _ in range(64):
        cells.append("." if rng.random() < p_empty else LETTERS[rng.integers(0, 12)])
    return "".join(cells)


def jitter_color(rng, c, amount=12):
    return tuple(float(np.clip(v + rng.normal(0, amount), 0, 255)) for v in c)


def make_theme(rng, printed):
    if printed:
        paper = rng.uniform(225, 255)
        light = (paper, paper, paper)
        if rng.random() < 0.6:
            return light, None  # hatched dark squares
        g = rng.uniform(140, 205)
        return light, (g, g, g)
    if rng.random() < 0.7:
        light, dark = THEMES[rng.integers(0, len(THEMES))]
        return jitter_color(rng, light, 8), jitter_color(rng, dark, 10)
    l = rng.uniform(185, 255)
    d = rng.uniform(60, min(175, l - 45))
    tint = rng.normal(0, 14, size=3)
    light = tuple(float(np.clip(l + t * 0.5, 0, 255)) for t in tint)
    tint = rng.normal(0, 22, size=3)
    dark = tuple(float(np.clip(d + t, 0, 255)) for t in tint)
    return light, dark


def paste(dst, piece, x, y, size):
    """Alpha-composite an RGBA float piece onto dst (BGR float 0..255) at (x, y)."""
    size = int(round(size))
    if size < 4:
        return
    im = cv2.resize(piece, (size, size), interpolation=cv2.INTER_AREA)
    x, y = int(round(x)), int(round(y))
    h, w = dst.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(w, x + size), min(h, y + size)
    if x1 <= x0 or y1 <= y0:
        return
    sub = im[y0 - y : y1 - y, x0 - x : x1 - x]
    a = sub[..., 3:4]
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - a) + sub[..., :3] * 255.0 * a


def render_board(rng, sets, set_name, placement):
    """Flat board render. Returns (BGR float image, margin in px around the 8x8 area)."""
    printed = rng.random() < 0.35
    if printed and rng.random() < 0.7:
        candidates = [s for s in PRINT_SETS if s in sets]
        if candidates:
            set_name = candidates[rng.integers(0, len(candidates))]
    pieces = sets[set_name]
    light, dark = make_theme(rng, printed)
    margin = int(rng.integers(0, 28)) if rng.random() < 0.8 else 0
    size = SQ * 8 + margin * 2
    page = light if printed else jitter_color(rng, (245, 245, 245), 6) if rng.random() < 0.5 else jitter_color(rng, (48, 46, 43), 10)
    img = np.empty((size, size, 3), np.float32)
    img[:] = page[::-1]

    board = np.empty((SQ * 8, SQ * 8, 3), np.float32)
    board[:] = light[::-1]
    hatch = None
    if dark is None:
        # Engraved-style hatching: thin diagonal lines on the dark squares.
        period = rng.uniform(4.5, 9)
        width = rng.uniform(0.25, 0.5)
        yy, xx = np.mgrid[0 : SQ * 8, 0 : SQ * 8].astype(np.float32)
        direction = 1 if rng.random() < 0.8 else -1
        phase = ((xx + direction * yy) / period) % 1.0
        ink = rng.uniform(20, 90)
        hatch = np.where(phase < width, ink, light[0]).astype(np.float32)
    for r in range(8):
        for c in range(8):
            if (r + c) % 2 == 1:
                ys, xs = slice(r * SQ, (r + 1) * SQ), slice(c * SQ, (c + 1) * SQ)
                if hatch is not None:
                    board[ys, xs] = hatch[ys, xs, None]
                else:
                    board[ys, xs] = dark[::-1]
    if not printed and rng.random() < 0.3:
        # Wood grain / texture.
        grain = cv2.GaussianBlur(rng.normal(0, 1, (SQ * 8, SQ * 8)).astype(np.float32), (0, 0), rng.uniform(1, 6))
        board += (grain / (grain.std() + 1e-6) * rng.uniform(2, 7))[..., None]

    # Screen furniture: last-move highlights, selection, move hints.
    if not printed and rng.random() < 0.35:
        for _ in range(rng.integers(1, 4)):
            r, c = rng.integers(0, 8, size=2)
            tint = np.array([(60, 210, 235), (70, 200, 170), (80, 110, 240), (240, 200, 120)][rng.integers(0, 4)], np.float32)
            a = rng.uniform(0.3, 0.55)
            ys, xs = slice(r * SQ, (r + 1) * SQ), slice(c * SQ, (c + 1) * SQ)
            board[ys, xs] = board[ys, xs] * (1 - a) + tint * a

    scale = rng.uniform(0.78, 1.0) if not printed else rng.uniform(0.8, 0.98)
    for sq, ch in enumerate(placement):
        if ch == ".":
            continue
        r, c = divmod(sq, 8)
        psize = SQ * scale
        ox = c * SQ + (SQ - psize) / 2 + rng.normal(0, 0.8)
        oy = r * SQ + (SQ - psize) / 2 + rng.normal(0, 0.8) + (rng.uniform(0, 2) if scale < 0.9 else 0)
        piece = pieces[LETTERS.index(ch)]
        if dark is None and (r + c) % 2 == 1 and rng.random() < 0.7:
            # Printed figurines sit in a cleared patch of the hatching.
            alpha = cv2.resize(piece[..., 3], (int(psize), int(psize)), interpolation=cv2.INTER_AREA)
            k = int(rng.integers(3, 7))
            halo = cv2.dilate(alpha, np.ones((k, k), np.uint8))
            x0, y0 = int(round(ox)), int(round(oy))
            x1, y1 = min(SQ * 8, x0 + halo.shape[1]), min(SQ * 8, y0 + halo.shape[0])
            xa, ya = max(0, x0), max(0, y0)
            h = halo[ya - y0 : y1 - y0, xa - x0 : x1 - x0, None]
            board[ya:y1, xa:x1] = board[ya:y1, xa:x1] * (1 - h) + light[0] * h
        paste(board, piece, ox, oy, psize)

    if not printed and rng.random() < 0.12:
        # Legal-move dots on a few empty squares.
        for sq in rng.permutation(64)[: rng.integers(1, 6)]:
            if placement[sq] != ".":
                continue
            r, c = divmod(int(sq), 8)
            overlay = board.copy()
            cv2.circle(overlay, (c * SQ + SQ // 2, r * SQ + SQ // 2), int(SQ * 0.15), (40, 40, 40), -1, cv2.LINE_AA)
            board[:] = board * 0.8 + overlay * 0.2

    font = [cv2.FONT_HERSHEY_SIMPLEX, cv2.FONT_HERSHEY_DUPLEX, cv2.FONT_HERSHEY_COMPLEX][rng.integers(0, 3)]
    if rng.random() < 0.45:
        # Coordinates inside the edge squares. (putText needs 8-bit pixels.)
        flipped = rng.random() < 0.3
        board8 = to_u8(board)
        for k in range(8):
            rank = str(k + 1 if flipped else 8 - k)
            file = "abcdefgh"[7 - k if flipped else k]
            col = 0 if rng.random() < 0.5 else 7
            for text, (r, c), corner in ((rank, (k, col), 0), (file, (7, k), 1)):
                colour = (dark if dark else (90, 90, 90)) if (r + c) % 2 == 0 else light
                px = c * SQ + (4 if corner == 0 and col == 0 else SQ - 13)
                py = r * SQ + (14 if corner == 0 else SQ - 5)
                cv2.putText(board8, text, (px, py), font, 0.38, tuple(float(v) for v in colour[::-1]), 1, cv2.LINE_AA)
        board[:] = board8

    img[margin : margin + SQ * 8, margin : margin + SQ * 8] = board
    if margin >= 3 and rng.random() < 0.8:
        t = int(rng.integers(1, min(4, margin)))
        gap = int(rng.integers(0, max(1, min(6, margin - t))))
        ink = (20, 20, 20) if printed or rng.random() < 0.5 else tuple(float(v) for v in (dark or (90, 90, 90))[::-1])
        a = margin - gap - t
        cv2.rectangle(img, (a, a), (size - 1 - a, size - 1 - a), ink, t)
    if margin >= 16 and rng.random() < 0.6:
        ink = (40, 40, 40) if np.mean(page) > 128 else (200, 200, 200)
        img8 = to_u8(img)
        for k in range(8):
            cv2.putText(img8, str(8 - k), (2, margin + k * SQ + SQ // 2 + 5), font, 0.4, ink, 1, cv2.LINE_AA)
            cv2.putText(img8, "abcdefgh"[k], (margin + k * SQ + SQ // 2 - 4, size - 4), font, 0.4, ink, 1, cv2.LINE_AA)
        img[:] = img8
    return img, margin, printed


def to_u8(img):
    return np.clip(img, 0, 255).astype(np.uint8)


def scatter_text(rng, canvas, ink, box=None):
    """Fill a region of an 8-bit canvas with lines of words."""
    h, w = canvas.shape[:2]
    x0, y0, x1, y1 = box or (0, 0, w, h)
    scale = rng.uniform(0.45, 0.9)
    line = int(26 * scale + rng.integers(6, 16))
    y = y0 + line
    while y < y1 - 4:
        x = x0 + int(rng.integers(8, 40))
        while x < x1 - 60:
            word = WORDS[rng.integers(0, len(WORDS))]
            cv2.putText(canvas, word, (x, y), cv2.FONT_HERSHEY_COMPLEX, scale, ink, 1, cv2.LINE_AA)
            x += int(len(word) * 19 * scale + 12 * scale)
        y += line
        if rng.random() < 0.08:
            y += line


def compose(rng, board_img, margin, printed):
    """Put the board on a page or screen. Returns (canvas, board corners in canvas px)."""
    shapes = [(960, 1280), (1280, 960), (1280, 720), (720, 1280), (1000, 1000)]
    w, h = shapes[rng.integers(0, len(shapes))]
    dark_ui = (not printed) and rng.random() < 0.4
    bg = rng.uniform(18, 60) if dark_ui else rng.uniform(205, 255)
    canvas = np.empty((h, w, 3), np.uint8)
    canvas[:] = np.clip(bg + rng.normal(0, 4, 3), 0, 255)
    ink = tuple([float(rng.uniform(170, 235))] * 3) if dark_ui else tuple([float(rng.uniform(15, 90))] * 3)
    if printed or rng.random() < 0.6:
        scatter_text(rng, canvas, ink)
    else:
        for _ in range(rng.integers(2, 9)):
            x0, y0 = int(rng.integers(0, w - 40)), int(rng.integers(0, h - 40))
            x1, y1 = x0 + int(rng.integers(40, w // 2)), y0 + int(rng.integers(20, h // 3))
            shade = float(np.clip(bg + rng.normal(0, 35), 0, 255))
            cv2.rectangle(canvas, (x0, y0), (x1, y1), (shade, shade, shade), -1)
            if rng.random() < 0.6:
                scatter_text(rng, canvas, ink, (x0, y0, min(w, x1), min(h, y1)))

    canvas = canvas.astype(np.float32)
    span = min(w, h)
    side = int(rng.uniform(0.28, 0.9) * span)
    board = cv2.resize(board_img, (side, side), interpolation=cv2.INTER_AREA)
    x = int(rng.integers(0, w - side + 1))
    y = int(rng.integers(0, h - side + 1))
    canvas[y : y + side, x : x + side] = board
    m = margin * side / board_img.shape[0]
    quad = np.array([[x + m, y + m], [x + side - m, y + m], [x + side - m, y + side - m], [x + m, y + side - m]], np.float32)
    # Pixel centres sit at integer coordinates; the board edge falls half a pixel before them.
    return canvas, quad - 0.5


def photograph(rng, canvas, quad, flat):
    h, w = canvas.shape[:2]
    if flat:
        # Screenshot: crop near the board, no perspective.
        pad = rng.uniform(0.0, 0.6) * (quad[1, 0] - quad[0, 0])
        x0 = int(max(0, quad[0, 0] - rng.uniform(0, pad)))
        y0 = int(max(0, quad[0, 1] - rng.uniform(0, pad)))
        x1 = int(min(w, quad[2, 0] + 1 + rng.uniform(0, pad)))
        y1 = int(min(h, quad[2, 1] + 1 + rng.uniform(0, pad)))
        img = canvas[y0:y1, x0:x1].copy()
        quad = quad - np.array([x0, y0], np.float32)
        if rng.random() < 0.5:
            s = rng.uniform(0.45, 1.0)
            img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
            quad = (quad + 0.5) * s - 0.5
        if rng.random() < 0.5:
            ok, enc = cv2.imencode(".jpg", np.clip(img, 0, 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(50, 96))])
            img = cv2.imdecode(enc, cv2.IMREAD_COLOR).astype(np.float32)
        return img, quad

    out_w, out_h = (w, h) if rng.random() < 0.7 else (int(w * 0.75), int(h * 0.75))
    for _ in range(40):
        # Tilted, slightly rotated view that keeps the whole board in frame.
        strength = rng.uniform(0.0, 0.16)
        src = np.array([[0, 0], [w, 0], [w, h], [0, h]], np.float32)
        dst = src + rng.uniform(-strength, strength, (4, 2)).astype(np.float32) * np.array([w, h], np.float32)
        angle = rng.normal(0, 4)
        zoom = rng.uniform(0.9, 1.5)
        centre = quad.mean(axis=0) + rng.normal(0, 0.08 * min(w, h), 2)
        R = cv2.getRotationMatrix2D((float(centre[0]), float(centre[1])), angle, zoom)
        R[:, 2] += np.array([w / 2, h / 2]) - centre
        P = cv2.getPerspectiveTransform(src, dst)
        M = np.vstack([R, [0, 0, 1]]) @ P
        S = np.diag([out_w / w, out_h / h, 1.0])
        M = S @ M
        q = cv2.perspectiveTransform(quad[None].astype(np.float64) + 0.5, M)[0] - 0.5
        if q[:, 0].min() > 3 and q[:, 1].min() > 3 and q[:, 0].max() < out_w - 4 and q[:, 1].max() < out_h - 4:
            edge = min(np.linalg.norm(q[k] - q[(k + 1) % 4]) for k in range(4))
            if edge > 150:
                break
    else:
        return None, None
    # warpPerspective maps pixel centres at integers; shift so M acts on continuous coordinates.
    T = np.array([[1, 0, 0.5], [0, 1, 0.5], [0, 0, 1]], np.float64)
    Ti = np.array([[1, 0, -0.5], [0, 1, -0.5], [0, 0, 1]], np.float64)
    border = float(rng.uniform(20, 235))
    img = cv2.warpPerspective(canvas, Ti @ M @ T, (out_w, out_h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(border, border * 0.95, border * 0.9))

    # Uneven light and a soft shadow.
    yy, xx = np.mgrid[0:out_h, 0:out_w].astype(np.float32)
    gx, gy = rng.normal(0, 0.18, 2)
    light = 1 + gx * (xx / out_w - 0.5) + gy * (yy / out_h - 0.5)
    if rng.random() < 0.4:
        cx, cy = rng.uniform(0, out_w), rng.uniform(0, out_h)
        rad = rng.uniform(0.2, 0.7) * max(out_w, out_h)
        light *= 1 - rng.uniform(0.1, 0.35) * np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * rad * rad))
    img *= (light * rng.uniform(0.6, 1.08))[..., None]
    img *= np.clip(1 + rng.normal(0, 0.05, 3), 0.85, 1.15).astype(np.float32)
    if rng.random() < 0.25:
        # Screen moire.
        f = rng.uniform(0.15, 0.6)
        theta = rng.uniform(0, np.pi)
        img *= (1 + rng.uniform(0.01, 0.04) * np.sin(f * (xx * np.cos(theta) + yy * np.sin(theta))))[..., None]
    sigma = abs(rng.normal(0, 1.0))
    if sigma > 0.25:
        img = cv2.GaussianBlur(img, (0, 0), min(2.6, sigma))
    if rng.random() < 0.15:
        k = int(rng.integers(3, 8))
        kernel = np.zeros((k, k), np.float32)
        kernel[k // 2] = 1.0 / k
        rot = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), rng.uniform(0, 180), 1)
        kernel = cv2.warpAffine(kernel, rot, (k, k))
        img = cv2.filter2D(img, -1, kernel / max(kernel.sum(), 1e-6))
    img += rng.normal(0, rng.uniform(0.5, 7), img.shape).astype(np.float32)
    gamma = rng.uniform(0.75, 1.3)
    img = 255.0 * np.power(np.clip(img, 0, 255) / 255.0, gamma)
    ok, enc = cv2.imencode(".jpg", np.clip(img, 0, 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(35, 96))])
    img = cv2.imdecode(enc, cv2.IMREAD_COLOR).astype(np.float32)
    return img, q.astype(np.float32)


def make_scene(rng, sets, names):
    set_name = names[rng.integers(0, len(names))]
    placement = random_placement(rng)
    board, margin, printed = render_board(rng, sets, set_name, placement)
    canvas, quad = compose(rng, board, margin, printed)
    flat = rng.random() < 0.2
    img, quad = photograph(rng, canvas, quad, flat)
    if img is None:
        return None
    return img, quad, placement, {"set": set_name, "printed": bool(printed), "flat": bool(flat)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pieces", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--sets", default="", help="comma-separated: only these sets")
    ap.add_argument("--exclude", default="", help="comma-separated: leave these sets out")
    args = ap.parse_args()

    only = set(filter(None, args.sets.split(","))) or None
    sets = load_sets(args.pieces, only, set(filter(None, args.exclude.split(","))))
    names = sorted(sets)
    os.makedirs(args.out, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    made = 0
    with open(os.path.join(args.out, "labels.jsonl"), "w") as labels:
        while made < args.count:
            scene = make_scene(rng, sets, names)
            if scene is None:
                continue
            img, quad, placement, meta = scene
            name = f"scene_{made:05d}.png"
            cv2.imwrite(os.path.join(args.out, name), np.clip(img, 0, 255).astype(np.uint8), [cv2.IMWRITE_PNG_COMPRESSION, 1])
            labels.write(json.dumps({"file": name, "quad": [[round(float(x), 2), round(float(y), 2)] for x, y in quad], "placement": placement, **meta}) + "\n")
            made += 1
    print(f"{made} scenes from {len(names)} sets -> {args.out}")


if __name__ == "__main__":
    main()
