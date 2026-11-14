/* @chesscam/recorder 0.2.0 (MIT), bundled by chess-lens/tools/vendor.mjs. See LICENSES.md in this folder. */

// node_modules/@chesscam/recorder/dist/constants.js
var MODEL_SIZE = 320;
var LABELS = ["b", "k", "n", "p", "q", "r", "B", "K", "N", "P", "Q", "R", "."];
var NUM_LABELS = LABELS.length;
var EMPTY = LABELS.indexOf(".");
var SQUARE_NAMES = [
  "a1",
  "b1",
  "c1",
  "d1",
  "e1",
  "f1",
  "g1",
  "h1",
  "a2",
  "b2",
  "c2",
  "d2",
  "e2",
  "f2",
  "g2",
  "h2",
  "a3",
  "b3",
  "c3",
  "d3",
  "e3",
  "f3",
  "g3",
  "h3",
  "a4",
  "b4",
  "c4",
  "d4",
  "e4",
  "f4",
  "g4",
  "h4",
  "a5",
  "b5",
  "c5",
  "d5",
  "e5",
  "f5",
  "g5",
  "h5",
  "a6",
  "b6",
  "c6",
  "d6",
  "e6",
  "f6",
  "g6",
  "h6",
  "a7",
  "b7",
  "c7",
  "d7",
  "e7",
  "f7",
  "g7",
  "h7",
  "a8",
  "b8",
  "c8",
  "d8",
  "e8",
  "f8",
  "g8",
  "h8"
];
var makeLabelMap = () => {
  const d = {};
  LABELS.forEach((label, i) => {
    d[label] = i;
  });
  return d;
};
var LABEL_MAP = makeLabelMap();
var makeSquareMap = () => {
  const d = {};
  SQUARE_NAMES.forEach((square, i) => {
    d[square] = i;
  });
  return d;
};
var SQUARE_MAP = makeSquareMap();
var zeros = (rows, columns) => {
  return Array.from({ length: rows }, () => Array(columns).fill(0));
};

// node_modules/@chesscam/recorder/dist/errors.js
var RecorderError = class extends Error {
  code;
  constructor(code, message = code, options) {
    super(message, options);
    this.name = "RecorderError";
    this.code = code;
  }
};

// node_modules/@chesscam/recorder/dist/vision/model.js
var CLASS_SYMBOLS = [".", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"];
var NUM_PROBS = 64 * CLASS_SYMBOLS.length;
var CORNERS = ["a8", "h8", "h1", "a1"];
var DEFAULT_MODEL_URL = "https://huggingface.co/PBatch23888/chessq-chesscam/resolve/0c3de0dd34a5e1a60d69e942045fb6dc0f82aeb4/chessq-chesscam-mnv4m-320-v1-fp16.tflite";
var LITERT_VERSION = "2.6.0";
var DEFAULT_WASM_URL = `https://cdn.jsdelivr.net/npm/@litertjs/core@${LITERT_VERSION}/wasm/`;
var canvas = null;
var blankPixels = () => new Uint8Array(MODEL_SIZE * MODEL_SIZE * 4);
var toOutputs = (arrays) => {
  const probs = arrays.find((array) => array.length === NUM_PROBS);
  if (probs === void 0) {
    throw new Error("Model has no square probabilities");
  }
  return { probs, centroids: arrays.find((array) => array.length === 64 * 2) ?? null };
};
var loadWorker = async (wasmUrl, modelUrl) => {
  const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
  const pending = /* @__PURE__ */ new Map();
  let nextId = 0;
  let stopped = null;
  const stop = (error) => {
    stopped = error;
    worker.terminate();
    pending.forEach(({ reject }) => {
      reject(error);
    });
    pending.clear();
  };
  worker.onmessage = (event) => {
    const response = event.data;
    const request = pending.get(response.id);
    pending.delete(response.id);
    if ("error" in response) {
      request?.reject(new Error(response.error));
    } else {
      request?.resolve(response.arrays);
    }
  };
  worker.onerror = (event) => {
    console.error("Piece detection worker failed", event.message);
    stop(new RecorderError("worker-stopped", event.message));
  };
  const send = (call, transfer = []) => {
    if (stopped !== null) {
      return Promise.reject(stopped);
    }
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      const request = { ...call, id };
      worker.postMessage(request, transfer);
    });
  };
  try {
    await send({
      type: "load",
      wasmUrl: new URL(wasmUrl, document.baseURI).href,
      modelUrl: new URL(modelUrl, document.baseURI).href
    });
  } catch (error) {
    stop(error);
    throw error;
  }
  return {
    run: async (video, roi) => {
      const pixels = video === null ? blankPixels() : getPixels(video, roi);
      return toOutputs(await send({ type: "run", pixels }, [pixels.buffer]));
    },
    delete: () => stop(new RecorderError("unloaded", "The model was unloaded"))
  };
};
var loaded = null;
var makeModel = (pieceModel) => {
  let current = pieceModel;
  return {
    detect: async (video, roi = null) => {
      if (current === null) {
        throw new RecorderError("not-ready", "The model is not loaded");
      }
      const { probs, centroids } = await current.run(video, roi);
      const width = roi === null ? video.videoWidth : roi.width;
      const height = roi === null ? video.videoHeight : roi.height;
      return {
        update: toUpdate(probs),
        direction: centroids === null ? null : toDirection(centroids, width, height)
      };
    },
    delete: () => {
      const model = current;
      current = null;
      loaded = null;
      model?.delete();
    }
  };
};
var loadModel = (options = {}) => {
  const modelUrl = options.modelUrl ?? DEFAULT_MODEL_URL;
  const wasmUrl = options.wasmUrl ?? DEFAULT_WASM_URL;
  const key = JSON.stringify([modelUrl, wasmUrl]);
  if (loaded !== null) {
    return loaded.key === key ? loaded.model : Promise.reject(new Error("A different model is already loaded; delete it first"));
  }
  const model = loadWorker(wasmUrl, modelUrl).then(makeModel);
  loaded = { key, model };
  void model.catch(() => {
    if (loaded?.model === model) {
      loaded = null;
    }
  });
  return model;
};
var getPixels = (video, roi) => {
  if (canvas === null) {
    canvas = new OffscreenCanvas(MODEL_SIZE, MODEL_SIZE);
  }
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (ctx === null) {
    throw new Error("Canvas is not ready");
  }
  ctx.imageSmoothingQuality = "high";
  if (roi === null) {
    ctx.drawImage(video, 0, 0, MODEL_SIZE, MODEL_SIZE);
  } else {
    ctx.drawImage(video, roi.x, roi.y, roi.width, roi.height, 0, 0, MODEL_SIZE, MODEL_SIZE);
  }
  const imageData = ctx.getImageData(0, 0, MODEL_SIZE, MODEL_SIZE);
  return new Uint8Array(imageData.data.buffer);
};
var toDirection = (centroids, width, height) => {
  const up = [0, 0];
  const right = [0, 0];
  for (let i = 0; i < 64; i++) {
    const rank = 7 - Math.floor(i / 8) - 3.5;
    const file = i % 8 - 3.5;
    const x = centroids[2 * i] * width;
    const y = centroids[2 * i + 1] * height;
    up[0] += rank * x;
    up[1] += rank * y;
    right[0] += file * x;
    right[1] += file * y;
  }
  const upNorm = Math.hypot(up[0], up[1]) || 1;
  const rightNorm = Math.hypot(right[0], right[1]) || 1;
  return [up[0] / upNorm + right[1] / rightNorm, up[1] / upNorm - right[0] / rightNorm];
};
var getOrientation = (direction) => {
  const turns = Math.round(Math.atan2(direction[0], -direction[1]) / (Math.PI / 2));
  return CORNERS.map((_, i) => CORNERS[((i - turns) % 4 + 4) % 4]);
};
var toUpdate = (probs) => {
  const update = zeros(64, NUM_LABELS);
  for (let i = 0; i < 64; i++) {
    const rank = 7 - Math.floor(i / 8);
    const file = i % 8;
    const square = 8 * rank + file;
    for (let j = 0; j < CLASS_SYMBOLS.length; j++) {
      update[square][LABEL_MAP[CLASS_SYMBOLS[j]]] = probs[i * CLASS_SYMBOLS.length + j];
    }
  }
  return update;
};
export {
  DEFAULT_MODEL_URL,
  DEFAULT_WASM_URL,
  LITERT_VERSION,
  getOrientation,
  loadModel
};
