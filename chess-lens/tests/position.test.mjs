import test from 'node:test';
import assert from 'node:assert/strict';
import { CLASSES } from '../web/core/classifier.js';
import { decode, looksFlipped, rotate180, rotate90, fenOf, cellsOf, placementOf, castlingOf, problemsOf } from '../web/core/position.js';

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';

/** One-hot probabilities for a placement, with optional per-square overrides {square: {letter: p}}. */
function probsFor(cells, overrides = {}) {
  const probs = new Float32Array(64 * CLASSES.length);
  cells.forEach((piece, s) => {
    const spec = overrides[s] || { [piece]: 1 };
    for (const [letter, p] of Object.entries(spec)) probs[s * CLASSES.length + CLASSES.indexOf(letter)] = p;
  });
  return probs;
}

test('FEN placement round-trips', () => {
  const cells = cellsOf(START);
  assert.equal(cells.length, 64);
  assert.equal(placementOf(cells), START);
  assert.equal(fenOf(cells, 'w'), `${START} w KQkq - 0 1`);
  assert.equal(cellsOf('8/8/8/8/8/8/8/7'), null);
  assert.equal(cellsOf('9/8/8/8/8/8/8/8'), null);
});

test('castling rights follow king and rook home squares', () => {
  assert.equal(castlingOf(cellsOf('r3k2r/8/8/8/8/8/8/R3K2R')), 'KQkq');
  assert.equal(castlingOf(cellsOf('r3k3/8/8/8/8/8/8/4K2R')), 'Kq');
  assert.equal(castlingOf(cellsOf('4k3/8/8/8/8/8/8/3K3R')), '-');
});

test('rotations', () => {
  const cells = cellsOf(START);
  assert.equal(placementOf(rotate180(cells)), 'RNBKQBNR/PPPPPPPP/8/8/8/8/pppppppp/rnbkqbnr');
  assert.deepEqual(rotate180(rotate180(cells)), cells);
  let turned = cells;
  for (let k = 0; k < 4; k++) turned = rotate90(turned);
  assert.deepEqual(turned, cells);
  // a8 (index 0) lands on h8 (index 7) after a clockwise quarter turn.
  const marked = new Array(64).fill('');
  marked[0] = 'r';
  assert.equal(rotate90(marked)[7], 'r');
});

test('a diagram drawn from the black side is detected', () => {
  const cells = cellsOf(START);
  assert.equal(looksFlipped(cells), false);
  assert.equal(looksFlipped(rotate180(cells)), true);
  // No pawns: fall back to the kings.
  assert.equal(looksFlipped(cellsOf('4k3/8/8/8/8/8/8/4K3')), false);
  assert.equal(looksFlipped(cellsOf('4K3/8/8/8/8/8/8/4k3')), true);
});

test('decode keeps exactly one king a side when the evidence allows', () => {
  const cells = cellsOf('4k3/8/8/8/8/8/8/3QK3');
  // The white queen on d1 is misread as a second white king, less confidently than the real one.
  const twoKings = decode(probsFor(cells, { 59: { K: 0.55, Q: 0.4 }, 60: { K: 0.9, Q: 0.1 } }));
  assert.equal(placementOf(twoKings.cells), '4k3/8/8/8/8/8/8/3QK3');
  assert.ok(twoKings.confidence[59] <= 0.5);

  // The black king is misread as a queen; it is the only square that resembles a king.
  const noKing = decode(probsFor(cells, { 4: { q: 0.6, k: 0.35 } }));
  assert.equal(placementOf(noKing.cells), '4k3/8/8/8/8/8/8/3QK3');

  // No king-like square at all: do not invent one.
  const none = decode(probsFor(cellsOf('8/8/8/8/8/8/8/3QK3')));
  assert.equal(placementOf(none.cells), '8/8/8/8/8/8/8/3QK3');
});

test('problems are reported', () => {
  assert.deepEqual(problemsOf(cellsOf(START)), []);
  assert.deepEqual(problemsOf(cellsOf('8/8/8/8/8/8/8/4K3')), ['No black king']);
  assert.ok(problemsOf(cellsOf('P3k3/8/8/8/8/8/8/4K3')).includes('Pawn on the first or last rank'));
});
