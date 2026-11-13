// Board-detection accuracy over a synthetic scene directory.
// Usage: node training/eval_detect.mjs <sceneDir> [--verbose]
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readPng } from '../tools/png.mjs';
import { detectBoard } from '../web/core/board.js';

const dir = process.argv[2];
const verbose = process.argv.includes('--verbose');
const rows = readFileSync(join(dir, 'labels.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
let found = 0, good = 0, ms = 0;
const errs = [];
const misses = [];
for (const row of rows) {
  const img = readPng(join(dir, row.file));
  const t0 = performance.now();
  const det = detectBoard(img);
  ms += performance.now() - t0;
  if (!det.ok) {
    misses.push(`${row.file} ${det.reason} set=${row.set} printed=${row.printed} flat=${row.flat}`);
    continue;
  }
  found++;
  const q = row.quad;
  const square = Math.hypot(q[1][0] - q[0][0], q[1][1] - q[0][1]) / 8;
  let worst = 0;
  for (let k = 0; k < 4; k++) worst = Math.max(worst, Math.hypot(det.quad[k][0] - q[k][0], det.quad[k][1] - q[k][1]));
  const rel = worst / square;
  errs.push(rel);
  if (rel < 0.15 && !det.quarterTurn) good++;
  else misses.push(`${row.file} off by ${rel.toFixed(2)} squares quarterTurn=${det.quarterTurn} corners=${det.corners} set=${row.set} printed=${row.printed} flat=${row.flat}`);
}
errs.sort((a, b) => a - b);
const pct = (p) => errs[Math.min(errs.length - 1, Math.floor(errs.length * p))]?.toFixed(3);
console.log(`scenes ${rows.length}  found ${found}  correct ${good} (${((100 * good) / rows.length).toFixed(1)}%)  ${(ms / rows.length).toFixed(0)} ms/scene`);
console.log(`corner error in squares: median ${pct(0.5)}  p90 ${pct(0.9)}  p99 ${pct(0.99)}`);
if (verbose) console.log(misses.join('\n'));
