// Locates the 8x8 board in an image and resamples it into per-square crops for the classifier.
import { toGray, shrink, blur, sample, inside } from './image.js';
import { findCorners, strongCorners } from './corners.js';
import { fitLattice, fitHomography, refine, apply, invert } from './lattice.js';

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
 * Find the 8x8 blocks of lattice cells that are boards. Squares must alternate with a light square
 * in the top-left corner, and the pattern must stop at the block's edge. A lattice can run across
 * two diagrams printed on the same grid, so more than one block may qualify.
 */
function findWindows(img, H, span, inliers) {
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

  const found = [];
  let cutOff = false;
  for (let a = a0; a <= a1; a++) {
    for (let b = b0; b <= b1; b++) {
      let held = 0;
      for (const q of inliers) if (q.i > a && q.i < a + 8 && q.j > b && q.j < b + 8) held++;
      if (held < 20) continue;
      let sum = 0, missing = 0;
      for (let dv = 0; dv < 8; dv++) {
        for (let du = 0; du < 8; du++) {
          const s = shade(a + du, b + dv);
          if (Number.isNaN(s)) missing++;
          else sum += s;
        }
      }
      if (missing > 0) {
        cutOff = true; // block runs out of frame
        continue;
      }
      const mean = sum / 64;
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
      if (Math.abs(corr) < 0.45 || Math.abs(pattern) / 64 < 4) continue;
      // `pattern` is positive when the top-left square is light, negative for a quarter-turned board.
      // A quarter-turned board is rare (it needs a sideways photo), so it has to win clearly.
      const score = (Math.abs(pattern) - Math.max(0, Math.sign(pattern) * ring)) * (pattern < 0 ? 0.75 : 1);
      found.push({ a, b, score, corr, held });
    }
  }
  // Keep the best block and any others that do not overlap one already kept.
  found.sort((p, q) => q.score - p.score);
  const kept = [];
  for (const w of found) {
    if (kept.length && w.score < kept[0].score * 0.5) break;
    if (kept.every((k) => Math.abs(k.a - w.a) >= 8 || Math.abs(k.b - w.b) >= 8)) kept.push(w);
  }
  return { windows: kept, cutOff };
}

/**
 * @param {{data: Uint8ClampedArray|Uint8Array, width: number, height: number}} image RGBA pixels
 * @returns {{ok: true, quad: number[][], homography: number[], gray: object, quarterTurn: boolean, corners: number, boards: number}
 *   | {ok: false, reason: string}}
 *   `quad` is the board outline in source pixels: top-left, top-right, bottom-right, bottom-left.
 *   `homography` maps board coordinates (0..8, 0..8) to source pixels. When the picture holds
 *   several diagrams (`boards` > 1) the one nearest the middle is returned: that is where the
 *   person is looking.
 */
export function detectBoard(image) {
  const gray = toGray(image.data, image.width, image.height);
  const longest = Math.max(image.width, image.height);
  // Coarse first: it is fast and right for a board that fills the view. Finer scales catch a
  // small diagram in a wide-angle photo; the coarsest catches a huge or blurry one.
  const sizes = [720];
  if (longest > 900) sizes.push(Math.min(longest, 1280));
  if (longest > 1600) sizes.push(Math.min(longest, 2400));
  if (longest > 2800) sizes.push(Math.min(longest, 4032));
  sizes.push(400);

  let best = null;
  let reason = 'no-board';
  for (const size of sizes) {
    const found = detectAtScale(gray, size);
    if (found.reason) reason = found.reason;
    if (found.candidate && (!best || found.candidate.off < best.off)) best = found.candidate;
    // A board near the middle is the one being looked at; otherwise a finer scale may reveal a
    // smaller diagram closer to the middle.
    if (best && best.off < 0.2) break;
  }
  if (!best) return { ok: false, reason };
  const homography = zoomRefine(gray, best.homography);
  const quad = [apply(homography, 0, 0), apply(homography, 8, 0), apply(homography, 8, 8), apply(homography, 0, 8)];
  return { ok: true, quad, homography, gray, quarterTurn: best.quarterTurn, corners: best.corners, boards: best.boards };
}

/**
 * A board found small in a large frame is located only roughly. Look again at just that region,
 * magnified, and keep the sharper outline when it agrees with the rough one.
 */
function zoomRefine(gray, homography) {
  const q = [apply(homography, 0, 0), apply(homography, 8, 0), apply(homography, 8, 8), apply(homography, 0, 8)];
  let side = 0;
  for (let k = 0; k < 4; k++) side += Math.hypot(q[k][0] - q[(k + 1) % 4][0], q[k][1] - q[(k + 1) % 4][1]) / 4;
  const pad = side * 0.2;
  const x0 = Math.max(0, Math.floor(Math.min(...q.map((p) => p[0])) - pad));
  const y0 = Math.max(0, Math.floor(Math.min(...q.map((p) => p[1])) - pad));
  const x1 = Math.min(gray.width, Math.ceil(Math.max(...q.map((p) => p[0])) + pad));
  const y1 = Math.min(gray.height, Math.ceil(Math.max(...q.map((p) => p[1])) + pad));
  const cw = x1 - x0;
  const ch = y1 - y0;
  // Nothing to gain when the region is most of the frame: the first pass already saw it this big.
  if (cw < 64 || ch < 64 || cw * ch > 0.6 * gray.width * gray.height) return homography;
  const data = new Float32Array(cw * ch);
  for (let y = 0; y < ch; y++) {
    data.set(gray.data.subarray((y0 + y) * gray.width + x0, (y0 + y) * gray.width + x1), y * cw);
  }
  const found = detectAtScale({ data, width: cw, height: ch }, 640).candidate;
  if (!found) return homography;
  const moved = [...found.homography];
  for (let c = 0; c < 3; c++) {
    moved[c] += x0 * moved[6 + c];
    moved[3 + c] += y0 * moved[6 + c];
  }
  const corners = [[0, 0], [8, 0], [8, 8], [0, 8]];
  for (let k = 0; k < 4; k++) {
    const [x, y] = apply(moved, corners[k][0], corners[k][1]);
    if (Math.hypot(x - q[k][0], y - q[k][1]) > side / 8 / 2) return homography; // a different board
  }
  return moved;
}

/**
 * One pass at a working size. Returns the most central board found, with `off` the distance of
 * its centre from the image centre as a fraction of the half-diagonal.
 */
function detectAtScale(gray, size) {
  const longest = Math.max(gray.width, gray.height);
  const scale = Math.min(1, size / longest);
  const w = Math.max(16, Math.round(gray.width * scale));
  const h = Math.max(16, Math.round(gray.height * scale));
  const small = blur(shrink(gray, w, h), 1.1);
  let pool = findCorners(small);
  let reason = null;

  // Fit a lattice, set that board's corners aside, and look again: another diagram on the page
  // has its own lattice, and may be fainter than the first.
  const candidates = [];
  for (let round = 0; round < 3; round++) {
    const corners = strongCorners(pool);
    if (corners.length < 16) break;
    const fit = fitLattice(corners);
    if (!fit) break;
    const { windows, cutOff } = findWindows(small, fit.H, fit.span, fit.inliers);
    if (cutOff && windows.length === 0) reason = 'cut-off';
    const Hinv = invert(fit.H);
    for (const win of windows) {
      const [cx, cy] = apply(fit.H, win.a + 4, win.b + 4);
      candidates.push({ fit, win, corners, off: Math.hypot(cx - w / 2, cy - h / 2) / (Math.hypot(w, h) / 2) });
    }
    const used = new Set(fit.inliers.map((q) => corners[q.k]));
    pool = pool.filter((p) => {
      if (used.has(p)) return false;
      if (!Hinv) return true;
      // Drop everything on a found board (piece artwork included), not just its lattice corners.
      const [u, v] = apply(Hinv, p.x, p.y);
      return !windows.some((win) => u > win.a - 0.5 && u < win.a + 8.5 && v > win.b - 0.5 && v < win.b + 8.5);
    });
  }
  if (candidates.length === 0) return { candidate: null, reason };
  // Every candidate already passed the pattern checks; contrast differs between diagrams, so
  // it does not get a say in which one the person meant.
  candidates.sort((p, q) => p.off - q.off);
  const { fit, win, corners, off } = candidates[0];

  const sx = gray.width / w;
  const sy = gray.height / h;
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
  if (!homography) return { candidate: null, reason };
  return {
    candidate: { homography, off, quarterTurn: win.corr < 0, corners: win.held, boards: candidates.length },
    reason,
  };
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
