// Reads a physical board with real pieces. The piece reader is the ChessCam model
// (@chesscam/recorder + LiteRT.js, bundled in vendor/chesscam); this file finds the board in the
// photo, tells the reader where to look, and turns its answer into this app's result shape.
import { detectBoard } from './core/board.js';
import { probsFromUpdate, roiAround, mean, seenFromBlack } from './core/physical.js';
import { decode, fenOf, problemsOf } from './core/position.js';

const MODEL_FILE = 'chessq-chesscam-mnv4m-320-v1-fp16.tflite';

let loading = null;
let ready = false;

async function served(url) {
  try {
    return (await fetch(url, { method: 'HEAD' })).ok;
  } catch {
    return false;
  }
}

/** True once the reader is loaded: the first load downloads about 24 MB unless it is bundled. */
export const realBoardReady = () => ready;

/**
 * Loads the reader once. Copies placed next to the app by `npm run vendor:offline` are used when
 * present (the iOS app ships them); otherwise the runtime comes from jsDelivr and the model from
 * Hugging Face.
 */
export function loadRealBoardReader() {
  if (!loading) {
    loading = (async () => {
      const { loadModel } = await import('./vendor/chesscam/recorder.js');
      const vendor = new URL('vendor/', document.baseURI);
      const options = {};
      if (await served(new URL('litert/litert_wasm_internal.wasm', vendor))) options.wasmUrl = new URL('litert/', vendor).href;
      const model = new URL(`chesscam-model/${MODEL_FILE}`, vendor);
      if (await served(model)) options.modelUrl = model.href;
      const reader = await loadModel(options);
      ready = true;
      return reader;
    })();
    loading.catch(() => {
      loading = null;
    });
  }
  return loading;
}

/**
 * @param {HTMLCanvasElement} canvas the photo
 * @returns same shape as core/scan.js `scan`, plus `roi` (where the reader looked) and `located`
 *   (whether the board outline was found; if not, the whole picture was read).
 */
export async function scanRealBoard(canvas) {
  const reader = await loadRealBoardReader();
  const t0 = performance.now();
  const { width, height } = canvas;
  const image = canvas.getContext('2d', { willReadFrequently: true }).getImageData(0, 0, width, height);
  const board = detectBoard(image);
  // Two framings of the same board, averaged: the reader was trained on hand-drawn regions, so
  // no single margin is "the" right one.
  const rois = board.ok
    ? [roiAround(board.quad, width, height, 'loose'), roiAround(board.quad, width, height, 'tight')]
    : [{ x: 0, y: 0, width, height }];
  const readings = [];
  const direction = [0, 0];
  for (const roi of rois) {
    const detection = await reader.detect(canvas, roi);
    readings.push(probsFromUpdate(detection.update));
    if (detection.direction) {
      direction[0] += detection.direction[0];
      direction[1] += detection.direction[1];
    }
  }
  const { cells, confidence } = decode(mean(readings));
  const unsure = [];
  for (let s = 0; s < 64; s++) if (confidence[s] < 0.8) unsure.push(s);
  return {
    ok: true,
    cells,
    confidence,
    fen: fenOf(cells, 'w'),
    // The reader works out the board's true orientation itself; this only says how to draw it.
    flipped: seenFromBlack(direction),
    quarterTurn: false,
    quad: board.ok ? board.quad : null,
    roi: rois[0],
    located: board.ok,
    problems: problemsOf(cells),
    unsure,
    ms: Math.round(performance.now() - t0),
  };
}
