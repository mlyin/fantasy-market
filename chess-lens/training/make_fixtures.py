"""Builds the small scene set that tests/scan.test.mjs runs the whole pipeline on.

Only piece sets whose licences allow redistribution are used (chessnut: Apache 2.0; fantasy,
spatial, celtic: MIT; rhosgfx: CC0), and scenes are shrunk to keep the repository light.

    python3 training/make_fixtures.py --pieces <rendered piece dir> --out tests/fixtures
"""

import argparse
import json
import os

import cv2
import numpy as np

import synth

SETS = {"chessnut", "fantasy", "spatial", "celtic", "rhosgfx"}
MAX_SIDE = 800
MIN_BOARD = 200  # px across after shrinking


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pieces", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--single", type=int, default=6)
    ap.add_argument("--double", type=int, default=2)
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()

    synth.PRINT_SETS[:] = sorted(SETS)
    sets = synth.load_sets(args.pieces, SETS)
    names = sorted(sets)
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out, exist_ok=True)
    rows = []
    plan = [False] * args.single + [True] * args.double
    index = 0
    while index < len(plan):
        two = plan[index]
        scene = synth.make_scene(rng, sets, names, two=two, realistic=True)
        if scene is None:
            continue
        img, quad, placement, meta = scene
        scale = min(1.0, MAX_SIDE / max(img.shape[:2]))
        if np.linalg.norm(quad[1] - quad[0]) * scale < MIN_BOARD:
            continue  # below the size the README says the scanner needs
        if scale < 1:
            img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            quad = (quad + 0.5) * scale - 0.5
        name = f"scene_{index:02d}.png"
        cv2.imwrite(os.path.join(args.out, name), np.clip(img, 0, 255).astype(np.uint8), [cv2.IMWRITE_PNG_COMPRESSION, 9])
        rows.append({"file": name, "quad": [[round(float(x), 2), round(float(y), 2)] for x, y in quad], "placement": placement, **meta})
        index += 1
    with open(os.path.join(args.out, "labels.jsonl"), "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    print(f"{len(rows)} fixtures -> {args.out}")


if __name__ == "__main__":
    main()
