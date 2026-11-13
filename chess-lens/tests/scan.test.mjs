// Runs the whole pipeline (find the board, read the pieces) on a few synthetic photos.
// The fixtures come from training/make_fixtures.py; labels.jsonl holds the expected answers.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readPng } from '../tools/png.mjs';
import { detectBoard } from '../web/core/board.js';
import { scan, loadModel } from '../web/core/scan.js';
import { rotate180 } from '../web/core/position.js';

const here = (path) => new URL(path, import.meta.url).pathname;
const rows = readFileSync(here('./fixtures/labels.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const weights = readFileSync(here('../web/model/pieces-v1.bin'));
const model = loadModel(
  JSON.parse(readFileSync(here('../web/model/pieces-v1.json'), 'utf8')),
  weights.buffer.slice(weights.byteOffset, weights.byteOffset + weights.byteLength),
);

for (const row of rows) {
  const label = `${row.file} (${row.set}${row.boards === 2 ? ', two diagrams' : ''})`;
  const image = readPng(here(`./fixtures/${row.file}`));

  test(`finds the board in ${label}`, () => {
    const found = detectBoard(image);
    assert.equal(found.ok, true);
    assert.equal(found.quarterTurn, false);
    const square = Math.hypot(row.quad[1][0] - row.quad[0][0], row.quad[1][1] - row.quad[0][1]) / 8;
    for (let k = 0; k < 4; k++) {
      const miss = Math.hypot(found.quad[k][0] - row.quad[k][0], found.quad[k][1] - row.quad[k][1]) / square;
      assert.ok(miss < 0.1, `corner ${k} is ${miss.toFixed(2)} squares off`);
    }
  });

  test(`reads every square of ${label}`, () => {
    const result = scan(model, image);
    assert.equal(result.ok, true);
    // Fixture positions are random, so the black-side guess carries no meaning here: undo it.
    const cells = result.flipped ? rotate180(result.cells) : result.cells;
    const expected = [...row.placement].map((c) => (c === '.' ? '' : c));
    assert.deepEqual(cells, expected);
  });
}

test('a picture with no board is reported, not guessed', () => {
  // Lines of grey blocks on a light gradient: page-like clutter, nothing checkered.
  const width = 320, height = 240;
  const data = new Uint8Array(width * height * 4);
  let seed = 7;
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (let i = 0; i < width * height; i++) {
    const v = 200 + Math.round(40 * ((i % width) / width));
    data.set([v, v, v, 255], i * 4);
  }
  for (let line = 20; line < height - 20; line += 18) {
    let x = 12;
    while (x < width - 40) {
      const w = 8 + Math.floor(rand() * 30);
      const shade = 40 + Math.floor(rand() * 60);
      for (let y = line; y < line + 9; y++) {
        for (let k = x; k < Math.min(width, x + w); k++) data.set([shade, shade, shade, 255], (y * width + k) * 4);
      }
      x += w + 6;
    }
  }
  const result = scan(model, { data, width, height });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no-board');
  assert.ok(result.message.length > 0);
});
