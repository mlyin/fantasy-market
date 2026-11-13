// End-to-end accuracy: photo -> placement, over a synthetic scene directory.
// Usage: node training/eval_scan.mjs <sceneDir> [modelPrefix] [--verbose] [--no-prior]
//   --no-prior switches off the material-count check, to measure the classifier on its own.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readPng } from '../tools/png.mjs';
import { scan, loadModel } from '../web/core/scan.js';
import { rotate180 } from '../web/core/position.js';

const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const verbose = process.argv.includes('--verbose');
const dir = args[0];
const prefix = args[1] || new URL('../web/model/pieces-v1', import.meta.url).pathname;
const weights = readFileSync(prefix + '.bin');
const model = loadModel(JSON.parse(readFileSync(prefix + '.json', 'utf8')), weights.buffer.slice(weights.byteOffset, weights.byteOffset + weights.byteLength));

const rows = readFileSync(join(dir, 'labels.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
let found = 0, perfect = 0, nearly = 0, squares = 0, wrong = 0, flagged = 0, ms = 0, orientationMisses = 0;
const bySet = new Map();
for (const row of rows) {
  const truth = [...row.placement].map((c) => (c === '.' ? '' : c));
  const result = scan(model, readPng(join(dir, row.file)), { materialPrior: !process.argv.includes('--no-prior') });
  const stats = bySet.get(row.set) || { n: 0, perfect: 0 };
  stats.n++;
  bySet.set(row.set, stats);
  if (!result.ok) {
    if (verbose) console.log(`${row.file} ${result.reason}`);
    continue;
  }
  found++;
  ms += result.ms;
  // The scanner turns a board it believes is drawn from Black's side; random test positions give
  // it no real evidence either way, so compare in whichever orientation it chose.
  const direct = result.flipped ? rotate180(result.cells) : result.cells;
  if (result.flipped) orientationMisses++;
  let errors = 0;
  for (let s = 0; s < 64; s++) if (direct[s] !== truth[s]) errors++;
  squares += 64;
  wrong += errors;
  if (errors === 0) {
    perfect++;
    stats.perfect++;
  }
  if (errors <= 1) nearly++;
  if (errors > 0) {
    const unsure = new Set(result.flipped ? result.unsure.map((s) => 63 - s) : result.unsure);
    let caught = 0;
    for (let s = 0; s < 64; s++) if (direct[s] !== truth[s] && unsure.has(s)) caught++;
    flagged += caught;
    if (verbose) console.log(`${row.file} ${errors} wrong (${caught} flagged) set=${row.set} printed=${row.printed}`);
  }
}
const pct = (a, b) => ((100 * a) / Math.max(1, b)).toFixed(1) + '%';
console.log(`scenes ${rows.length}  board found ${pct(found, rows.length)}  ${(ms / Math.max(1, found)).toFixed(0)} ms/scan`);
console.log(`whole position exactly right ${pct(perfect, rows.length)}  at most one square wrong ${pct(nearly, rows.length)}`);
console.log(`square accuracy ${((100 * (squares - wrong)) / Math.max(1, squares)).toFixed(3)}%  wrong squares flagged as uncertain ${pct(flagged, wrong)}`);
if (verbose) {
  const worst = [...bySet.entries()].map(([set, s]) => [set, s.perfect / s.n, s.n]).sort((a, b) => a[1] - b[1]);
  console.log('per set (exact rate, scenes): ' + worst.map(([set, r, n]) => `${set} ${(r * 100).toFixed(0)}% (${n})`).join(', '));
}
