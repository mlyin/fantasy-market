import test from 'node:test';
import assert from 'node:assert/strict';
import { CLASSES } from '../web/core/classifier.js';
import { probsFromUpdate, roiAround, mean, seenFromBlack } from '../web/core/physical.js';
import { decode, placementOf } from '../web/core/position.js';

// The recorder's layout, restated here on purpose: squares a1..h8, classes in this order.
const LABELS = ['b', 'k', 'n', 'p', 'q', 'r', 'B', 'K', 'N', 'P', 'Q', 'R', '.'];
const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';

/** A recorder-style `update` for a FEN placement. */
function updateFor(placement) {
  const update = Array.from({ length: 64 }, () => new Array(13).fill(0));
  placement.split('/').forEach((row, r) => {
    let file = 0;
    for (const ch of row) {
      if (ch >= '1' && ch <= '8') {
        for (let k = 0; k < Number(ch); k++) update[(7 - r) * 8 + file++][LABELS.indexOf('.')] = 1;
      } else update[(7 - r) * 8 + file++][LABELS.indexOf(ch)] = 1;
    }
  });
  return update;
}

test('the reader output maps onto this app’s squares and classes', () => {
  const probs = probsFromUpdate(updateFor(START));
  assert.equal(probs.length, 64 * CLASSES.length);
  assert.equal(placementOf(decode(probs).cells), START);
  const lopsided = 'r3k3/8/8/8/8/8/5P2/4K2Q';
  assert.equal(placementOf(decode(probsFromUpdate(updateFor(lopsided))).cells), lopsided);
});

test('the region handed to the reader surrounds the board and stays inside the photo', () => {
  const quad = [[400, 300], [1200, 320], [1250, 1000], [350, 980]];
  const loose = roiAround(quad, 1600, 1200, 'loose');
  const tight = roiAround(quad, 1600, 1200, 'tight');
  for (const roi of [loose, tight]) {
    assert.ok(roi.x <= 350 && roi.y <= 300 && roi.x + roi.width >= 1250 && roi.y + roi.height >= 1000);
    assert.ok(roi.x >= 0 && roi.y >= 0 && roi.x + roi.width <= 1600 && roi.y + roi.height <= 1200);
  }
  assert.ok(loose.width > tight.width && loose.height > tight.height);
  // More room above (far pieces stand up past the far edge) than below.
  assert.ok(300 - loose.y > loose.y + loose.height - 1000);
  // A board at the edge of the frame is clamped, not pushed out.
  const edge = roiAround([[0, 0], [800, 0], [800, 800], [0, 800]], 800, 800);
  assert.deepEqual(edge, { x: 0, y: 0, width: 800, height: 800 });
});

test('readings are averaged', () => {
  assert.deepEqual([...mean([new Float32Array([0, 1]), new Float32Array([1, 0])])], [0.5, 0.5]);
});

test('which side the camera is on', () => {
  assert.equal(seenFromBlack([0, -1]), false); // rank 8 away from the viewer: White's seat
  assert.equal(seenFromBlack([0.2, 1]), true); // rank 8 towards the viewer: Black's seat
  assert.equal(seenFromBlack([1, 0.3]), false); // side-on: leave it as drawn
  assert.equal(seenFromBlack(null), false);
});
