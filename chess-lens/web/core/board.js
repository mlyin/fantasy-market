// Locates the 8x8 board in an image and resamples it into per-square crops for the classifier.
import { toGray, shrink, blur, sample, inside } from './image.js';
import { findCorners } from './corners.js';
import { fitLattice, fitHomography, refine, apply } from './lattice.js';

/** Geometry shared with the training pipeline: a crop is CROP px wide and covers 4/3 of a square. */
export const SQUARE = 24;
export const MARGIN = 4;
export const CROP = SQUARE + 2 * MARGIN;
const RECT = SQUARE * 8 + 2 * MARGIN;

// Sample points inside a cell that pieces rarely cover (corners and edge midpoints).
const CELL_TAPS = [
  [0.15, 0.15], [0.85, 0.15], [0.15, 0.85], [0.85, 0.85],
  [0.5, 0.1], [0.5, 0.9], [0.1, 0.5], [0.9, 0.5],
];

function cellShade(img, H, u, v, scratch) {
  for (let t = 0; t < CELL_TAPS.length; t++) {
    const [x, y] = apply(H, u + CELL_TAPS[t][0], v + CELL_TAPS[t][1]);
    if (!inside(img, x, y, 1)) return NaN;
    scratch[t] = sample(img, x, y);
  }
  scratch.sort();
  return (scratch[3] + scratch[4]) / 2;
}

/**
 * Pick which 8x8 block of lattice cells is the board. Squares must alternate with a light square
 * in the top-left corner, and the pattern must stop at the block's edge.
 */
function chooseWindow(img, H, span, inliers) {
  const shades = new Map();
  const scratch = new Float32Array(CELL_TAPS.length);
  const shade = (u, v) => {
    const key = (u + 32) * 128 + (v + 32);
    let s = shades.get(key);
    if (s === undefined) {
      s = cellShade(img, H, u, v, scratch);
      shades.set(key, s);
    }
    return s;
  };
  // Search every block that overlaps the fitted corners; the checker pattern decides.
  const a0 = span.i0 - 8, a1 = span.i1;
  const b0 = span.j0 - 8, b1 = span.j1;

  let best = null;
  for (let a = a0; a <= a1; a++) {
    for (let b = b0; b <= b1; b++) {
      let sum = 0, count = 0, missing = 0;
      for (let dv = 0; dv < 8; dv++) {
        for (let du = 0; du < 8; du++) {
          const s = shade(a + du, b + dv);
          if (Number.isNaN(s)) missing++;
          else {
            sum += s;
            count++;
          }
        }
      }
      if (missing > 0) continue; // block runs out of frame
      let held = 0;
      for (const q of inliers) if (q.i > a && q.i < a + 8 && q.j > b && q.j < b + 8) held++;
      if (held < inliers.length * 0.5) continue;
      const mean = sum / count;
      let pattern = 0, energy = 0;
      for (let dv = 0; dv < 8; dv++) {
        for (let du = 0; du < 8; du++) {
          const d = shade(a + du, b + dv) - mean;
          pattern += (du + dv) % 2 === 0 ? d : -d;
          energy += Math.abs(d);
        }
      }
      let ring = 0;
      for (let dv = -1; dv <= 8; dv++) {
        for (let du = -1; du <= 8; du++) {
          if (du >= 0 && du <= 7 && dv >= 0 && dv <= 7) continue;
          const s = shade(a + du, b + dv);
          if (Number.isNaN(s)) continue;
          const d = s - mean;
          ring += (du + dv + 2) % 2 === 0 ? d : -d;
        }
      }
      const corr = energy > 0 ? pattern / energy : 0;
      // `pattern` is positive when the top-left square is light, negative for a quarter-turned board.
      // A quarter-turned board is rare (it needs a sideways photo), so it has to win clearly.
      const score = (Math.abs(pattern) - Math.max(0, Math.sign(pattern) * ring)) * (pattern < 0 ? 0.75 : 1);
      if (!best || score > best.score) best = { a, b, score, corr, contrast: Math.abs(pattern) / 64 };
    }
  }
  return best;
}

/**
 * @param {{data: Uint8ClampedArray|Uint8Array, width: number, height: number}} image RGBA pixels
 * @returns {{ok: true, quad: number[][], homography: number[], gray: object, quarterTurn: boolean, corners: number}
 *   | {ok: false, reason: string}}
 *   `quad` is the board outline in source pixels: top-left, top-right, bottom-right, bottom-left.
 *   `homography` maps board coordinates (0..8, 0..8) to source pixels.
 */
export function detectBoard(image) {
  const gray = toGray(image.data, image.width, image.height);
  const longest = Math.max(image.width, image.height);
  const sizes = [720, 1280, 400].filter((s, idx) => idx === 0 || (idx === 1 ? longest > 900 : true));
  let reason = 'no-board';
  for (const size of sizes) {
    const scale = Math.min(1, size / longest);
    const w = Math.max(16, Math.round(image.width * scale));
    const h = Math.max(16, Math.round(image.height * scale));
    const small = blur(shrink(gray, w, h), 1.1);
    const corners = findCorners(small);
    const fit = fitLattice(corners);
    if (!fit) continue;
    const win = chooseWindow(small, fit.H, fit.span, fit.inliers);
    if (!win) {
      reason = 'cut-off';
      continue;
    }
    if (Math.abs(win.corr) < 0.45 || win.contrast < 4) continue;
    const sx = image.width / w;
    const sy = image.height / h;
    // Board coordinates (0..8) -> source pixels. Pixel centres sit at integer coordinates in both
    // images, hence the half-pixel shifts when changing scale.
    const H = refine(corners, fit.H, win.a, win.b);
    const src = [];
    const dst = [];
    for (let v = 0; v <= 8; v += 2) {
      for (let u = 0; u <= 8; u += 2) {
        const [x, y] = apply(H, win.a + u, win.b + v);
        src.push([u, v]);
        dst.push([(x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5]);
      }
    }
    const homography = fitHomography(src, dst);
    if (!homography) continue;
    const quad = [apply(homography, 0, 0), apply(homography, 8, 0), apply(homography, 8, 8), apply(homography, 0, 8)];
    return {
      ok: true,
      quad,
      homography,
      gray,
      quarterTurn: win.corr < 0,
      corners: fit.inliers.length,
    };
  }
  return { ok: false, reason };
}

/**
 * Resample the board to a flat RECT x RECT image and cut 64 overlapping crops.
 * @returns {{crops: Uint8Array, rect: Uint8Array, size: number}} crops are 64 * CROP * CROP bytes,
 *   row-major from the top-left square; rect is the full normalised board (size x size bytes).
 */
export function rectify(gray, homography, { quarterTurn = false } = {}) {
  // Pre-shrink so that one output pixel covers at most ~1.5 source pixels per supersample tap.
  const q = [apply(homography, 0, 0), apply(homography, 8, 0), apply(homography, 8, 8), apply(homography, 0, 8)];
  let perimeter = 0;
  for (let k = 0; k < 4; k++) perimeter += Math.hypot(q[k][0] - q[(k + 1) % 4][0], q[k][1] - q[(k + 1) % 4][1]);
  const squarePx = perimeter / 32;
  const factor = Math.max(1, Math.floor(squarePx / (SQUARE * 3)));
  const src = factor > 1 ? shrink(gray, Math.floor(gray.width / factor), Math.floor(gray.height / factor)) : gray;
  const fx = src.width / gray.width;
  const fy = src.height / gray.height;

  const out = new Float32Array(RECT * RECT);
  const taps = [0.25, 0.75];
  for (let py = 0; py < RECT; py++) {
    for (let px = 0; px < RECT; px++) {
      let s = 0;
      for (const ty of taps) {
        for (const tx of taps) {
          // Board coordinate of this sub-sample; the image starts MARGIN px outside the board.
          let u = (px + tx - MARGIN) / SQUARE;
          let v = (py + ty - MARGIN) / SQUARE;
          if (quarterTurn) [u, v] = [v, 8 - u];
          const [x, y] = apply(homography, u, v);
          s += sample(src, (x + 0.5) * fx - 0.5, (y + 0.5) * fy - 0.5);
        }
      }
      out[py * RECT + px] = s / 4;
    }
  }

  // Stretch contrast between the 2nd and 98th percentiles of the board area.
  const hist = new Uint32Array(256);
  for (let i = 0; i < out.length; i++) hist[Math.max(0, Math.min(255, Math.round(out[i])))]++;
  const lowCut = out.length * 0.02;
  const highCut = out.length * 0.98;
  let lo = 0, hi = 255, acc = 0;
  for (let i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= lowCut) {
      lo = i;
      break;
    }
  }
  acc = 0;
  for (let i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= highCut) {
      hi = i;
      break;
    }
  }
  const gain = 255 / Math.max(8, hi - lo);
  const rect = new Uint8Array(RECT * RECT);
  for (let i = 0; i < out.length; i++) rect[i] = Math.max(0, Math.min(255, Math.round((out[i] - lo) * gain)));

  const crops = new Uint8Array(64 * CROP * CROP);
  for (let sq = 0; sq < 64; sq++) {
    const ox = (sq % 8) * SQUARE;
    const oy = Math.floor(sq / 8) * SQUARE;
    const base = sq * CROP * CROP;
    for (let y = 0; y < CROP; y++) {
      const from = (oy + y) * RECT + ox;
      crops.set(rect.subarray(from, from + CROP), base + y * CROP);
    }
  }
  return { crops, rect, size: RECT };
}
