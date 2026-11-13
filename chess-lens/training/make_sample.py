"""Builds web/samples/book-page.jpg: a synthetic 'photo of a book page' the app can demo with.

Uses only the Apache-licensed chessnut pieces, so the picture can ship with the app.
Position: Morphy v Duke Karl / Count Isouard, Paris 1858, White to play 16.Qb8+.

    python3 training/make_sample.py --pieces <rendered piece dir> --out web/samples/book-page.jpg
"""

import argparse

import cv2
import numpy as np

import synth

FEN = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4"


def placement_from_fen(fen):
    out = ""
    for ch in fen:
        if ch == "/":
            continue
        out += "." * int(ch) if ch.isdigit() else ch
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pieces", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    synth.PRINT_SETS[:] = ["chessnut"]
    sets = synth.load_sets(args.pieces, {"chessnut"})
    placement = placement_from_fen(FEN)
    seed = args.seed
    while True:
        rng = np.random.default_rng(seed)
        board, margin, printed = synth.render_board(rng, sets, "chessnut", placement)
        if printed and margin >= 10:
            canvas, quad = synth.compose(rng, board, margin, printed)
            side = quad[1, 0] - quad[0, 0]
            if canvas.shape[0] > canvas.shape[1] and 0.5 * canvas.shape[1] < side < 0.75 * canvas.shape[1]:
                img, q = synth.photograph(rng, canvas, quad, False)
                if img is not None:
                    break
        seed += 1
    cv2.imwrite(args.out, np.clip(img, 0, 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 88])
    print(f"seed {seed} -> {args.out} {img.shape[1]}x{img.shape[0]}")


if __name__ == "__main__":
    main()
