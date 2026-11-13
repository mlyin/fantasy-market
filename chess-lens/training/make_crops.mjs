// Turns synthetic scenes into classifier training crops using the exact code path the app runs.
// Usage: node training/make_crops.mjs <sceneDir>
// Writes crops.u8 (N * 64 * CROP * CROP), labels.u8 (N * 64 class ids) and crops.json next to the scenes.
//
// Every scene is cut twice: once with the outline the detector actually found (so the classifier
// learns the detector's real residual error) and once with the true outline plus corner jitter.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readPng } from '../tools/png.mjs';
import { detectBoard, rectify, CROP } from '../web/core/board.js';
import { fitHomography } from '../web/core/lattice.js';
import { toGray } from '../web/core/image.js';
import { CLASSES } from '../web/core/classifier.js';

const dir = process.argv[2];
const rows = readFileSync(join(dir, 'labels.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const BOARD = [[0, 0], [8, 0], [8, 8], [0, 8]];
let seed = 12345;
const rand = () => {
  // mulberry32
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

const cropChunks = [];
const labelChunks = [];
const boards = [];
let detected = 0;
for (const row of rows) {
  const img = readPng(join(dir, row.file));
  const labels = Uint8Array.from(row.placement, (ch) => (ch === '.' ? 0 : CLASSES.indexOf(ch)));
  const q = row.quad;
  const square = Math.hypot(q[1][0] - q[0][0], q[1][1] - q[0][1]) / 8;

  const det = detectBoard(img);
  let gray = det.ok ? det.gray : toGray(img.data, img.width, img.height);
  if (det.ok && !det.quarterTurn) {
    let worst = 0;
    for (let k = 0; k < 4; k++) worst = Math.max(worst, Math.hypot(det.quad[k][0] - q[k][0], det.quad[k][1] - q[k][1]));
    if (worst / square < 0.12) {
      detected++;
      cropChunks.push(rectify(gray, det.homography).crops);
      labelChunks.push(labels);
      boards.push({ file: row.file, set: row.set, source: 'detected' });
    }
  }
  const amount = rand() < 0.5 ? 0.03 : 0.07;
  const jittered = q.map(([x, y]) => [x + (rand() * 2 - 1) * amount * square, y + (rand() * 2 - 1) * amount * square]);
  const H = fitHomography(BOARD, jittered);
  if (H) {
    cropChunks.push(rectify(gray, H).crops);
    labelChunks.push(labels);
    boards.push({ file: row.file, set: row.set, source: 'jittered' });
  }
}
const crops = new Uint8Array(cropChunks.length * 64 * CROP * CROP);
cropChunks.forEach((c, i) => crops.set(c, i * 64 * CROP * CROP));
const labels = new Uint8Array(labelChunks.length * 64);
labelChunks.forEach((c, i) => labels.set(c, i * 64));
writeFileSync(join(dir, 'crops.u8'), crops);
writeFileSync(join(dir, 'labels.u8'), labels);
writeFileSync(join(dir, 'crops.json'), JSON.stringify({ crop: CROP, boards }));
console.log(`${dir}: ${rows.length} scenes, detector matched ${detected}, wrote ${boards.length} boards`);
