// Photo in, position out. The only entry point the UI, the tests and the training tools need.
import { detectBoard, rectify } from './board.js';
import { classify, loadModel } from './classifier.js';
import { decode, looksFlipped, rotate180, fenOf, problemsOf } from './position.js';

export { loadModel };

export const REASONS = {
  'no-board': 'No board found. Fill more of the view with the diagram and hold steady.',
  'cut-off': 'The board runs out of the picture. Get all four edges in view.',
};

/**
 * @param {object} model from loadModel
 * @param {{data: Uint8ClampedArray|Uint8Array, width: number, height: number}} image RGBA pixels
 * @returns {{ok: false, reason: string, message: string} | {
 *   ok: true, cells: string[], confidence: number[], fen: string, flipped: boolean,
 *   quarterTurn: boolean, quad: number[][], problems: string[], unsure: number[], ms: number}}
 *   `cells` is row-major from a8 after orientation; `flipped` says the diagram was drawn from
 *   Black's side; `unsure` lists square indexes worth a second look.
 */
export function scan(model, image) {
  const t0 = performance.now();
  const board = detectBoard(image);
  if (!board.ok) return { ok: false, reason: board.reason, message: REASONS[board.reason] };
  const { crops } = rectify(board.gray, board.homography, { quarterTurn: board.quarterTurn });
  const probs = classify(model, crops);
  let { cells, confidence } = decode(probs);
  const flipped = looksFlipped(cells);
  if (flipped) {
    cells = rotate180(cells);
    confidence = rotate180(confidence);
  }
  const unsure = [];
  for (let s = 0; s < 64; s++) if (confidence[s] < 0.8) unsure.push(s);
  return {
    ok: true,
    cells,
    confidence,
    fen: fenOf(cells, 'w'),
    flipped,
    quarterTurn: board.quarterTurn,
    quad: board.quad,
    problems: problemsOf(cells),
    unsure,
    ms: Math.round(performance.now() - t0),
  };
}
