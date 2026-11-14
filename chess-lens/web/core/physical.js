// Glue for reading a physical board: where to look in the photo, and how the reader's output maps
// onto this app's square and class layout. Pure functions, so they run under Node for the tests.
import { CLASSES } from './classifier.js';

// @chesscam/recorder's class order (dist/constants.js): black pieces, white pieces, empty.
const RECORDER_LABELS = ['b', 'k', 'n', 'p', 'q', 'r', 'B', 'K', 'N', 'P', 'Q', 'R', ''];
const TO_CLASS = RECORDER_LABELS.map((label) => CLASSES.indexOf(label));

/**
 * @param {number[][]} update 64 rows in square order a1..h8, 13 scores each in the recorder's order
 * @returns {Float32Array} 64 * 13 in this app's layout: squares a8..h1, classes as in CLASSES
 */
export function probsFromUpdate(update) {
  const probs = new Float32Array(64 * CLASSES.length);
  for (let square = 0; square < 64; square++) {
    const rank = Math.floor(square / 8);
    const file = square % 8;
    const cell = (7 - rank) * 8 + file;
    for (let j = 0; j < RECORDER_LABELS.length; j++) probs[cell * CLASSES.length + TO_CLASS[j]] = update[square][j];
  }
  return probs;
}

// Padding around the board outline, in squares. Pieces stand up from the board, so from a seat at
// the table the far ranks' pieces reach past the far edge: the top gets the most room.
const PADDING = {
  loose: { side: 0.6, top: 1.4, bottom: 0.6 },
  tight: { side: 0.25, top: 0.8, bottom: 0.3 },
};

/**
 * The rectangle of the photo to hand to the reader.
 * @param {number[][]} quad board outline in pixels
 * @param {'loose'|'tight'} fit
 * @returns {{x: number, y: number, width: number, height: number}} whole pixels inside the image
 */
export function roiAround(quad, imageWidth, imageHeight, fit = 'loose') {
  const xs = quad.map((p) => p[0]);
  const ys = quad.map((p) => p[1]);
  const left = Math.min(...xs), right = Math.max(...xs);
  const top = Math.min(...ys), bottom = Math.max(...ys);
  const sx = (right - left) / 8;
  const sy = (bottom - top) / 8;
  const pad = PADDING[fit];
  const x0 = Math.max(0, Math.floor(left - pad.side * sx));
  const y0 = Math.max(0, Math.floor(top - pad.top * sy));
  const x1 = Math.min(imageWidth, Math.ceil(right + pad.side * sx));
  const y1 = Math.min(imageHeight, Math.ceil(bottom + pad.bottom * sy));
  return { x: x0, y: y0, width: Math.max(1, x1 - x0), height: Math.max(1, y1 - y0) };
}

/** Element-wise mean of equally sized arrays. */
export function mean(arrays) {
  const out = new Float32Array(arrays[0].length);
  for (const a of arrays) for (let i = 0; i < out.length; i++) out[i] += a[i] / arrays.length;
  return out;
}

/**
 * The reader reports which way rank 8 points in the picture. When it points down the image, the
 * camera is on Black's side of the board, and the on-screen board is drawn from Black's side too
 * so it matches what the wearer sees.
 * @param {number[]|null} direction [dx, dy] in image pixels
 */
export function seenFromBlack(direction) {
  return Boolean(direction) && direction[1] > 0 && Math.abs(direction[1]) >= Math.abs(direction[0]);
}
