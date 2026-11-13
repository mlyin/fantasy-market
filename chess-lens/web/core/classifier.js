// Tiny CNN that labels one square crop as empty or one of the twelve pieces. Plain typed-array
// inference so the same file runs in a browser, a WKWebView and Node with no runtime dependency.
import { CROP } from './board.js';

export const CLASSES = ['', 'P', 'N', 'B', 'R', 'Q', 'K', 'p', 'n', 'b', 'r', 'q', 'k'];

/**
 * @param {object} manifest parsed pieces-*.json: { input, layers: [{type, ...}], tensors: {name: {shape, offset}} }
 * @param {ArrayBuffer} buffer little-endian float32 weights
 */
export function loadModel(manifest, buffer) {
  if (manifest.input !== CROP) throw new Error(`model expects ${manifest.input}px crops, pipeline cuts ${CROP}px`);
  const all = new Float32Array(buffer);
  const tensor = (name) => {
    const t = manifest.tensors[name];
    const size = t.shape.reduce((a, b) => a * b, 1);
    return { shape: t.shape, data: all.subarray(t.offset, t.offset + size) };
  };
  const layers = manifest.layers.map((l) =>
    l.type === 'conv' || l.type === 'dense' ? { ...l, w: tensor(l.weight), b: tensor(l.bias) } : l,
  );
  return { layers, classes: manifest.classes, version: manifest.version };
}

/** 3x3 convolution, stride 1, zero padding, followed by ReLU. Weights are [out, in, 3, 3]. */
function conv3(input, inC, size, w, b) {
  const outC = w.shape[0];
  const plane = size * size;
  const out = new Float32Array(outC * plane);
  const wd = w.data;
  const last = size - 1;
  for (let oc = 0; oc < outC; oc++) {
    const o = oc * plane;
    out.fill(b.data[oc], o, o + plane);
    for (let ic = 0; ic < inC; ic++) {
      const i = ic * plane;
      const wBase = (oc * inC + ic) * 9;
      for (let ky = 0; ky < 3; ky++) {
        const w0 = wd[wBase + ky * 3];
        const w1 = wd[wBase + ky * 3 + 1];
        const w2 = wd[wBase + ky * 3 + 2];
        const yStart = ky === 0 ? 1 : 0;
        const yEnd = ky === 2 ? last : size;
        for (let y = yStart; y < yEnd; y++) {
          const dst = o + y * size;
          const src = i + (y + ky - 1) * size;
          // Edge columns have a neighbour missing; the interior takes all three taps at once.
          out[dst] += w1 * input[src] + w2 * input[src + 1];
          for (let x = 1; x < last; x++) {
            out[dst + x] += w0 * input[src + x - 1] + w1 * input[src + x] + w2 * input[src + x + 1];
          }
          out[dst + last] += w0 * input[src + last - 1] + w1 * input[src + last];
        }
      }
    }
  }
  for (let k = 0; k < out.length; k++) if (out[k] < 0) out[k] = 0;
  return out;
}

function pool2(input, channels, size) {
  const half = size >> 1;
  const out = new Float32Array(channels * half * half);
  for (let c = 0; c < channels; c++) {
    const i = c * size * size;
    const o = c * half * half;
    for (let y = 0; y < half; y++) {
      for (let x = 0; x < half; x++) {
        const p = i + y * 2 * size + x * 2;
        out[o + y * half + x] = Math.max(input[p], input[p + 1], input[p + size], input[p + size + 1]);
      }
    }
  }
  return out;
}

function dense(input, w, b, relu) {
  const [outN, inN] = w.shape;
  const out = new Float32Array(outN);
  for (let o = 0; o < outN; o++) {
    let s = b.data[o];
    const base = o * inN;
    for (let i = 0; i < inN; i++) s += w.data[base + i] * input[i];
    out[o] = relu && s < 0 ? 0 : s;
  }
  return out;
}

/**
 * @param {Uint8Array} crops 64 * CROP * CROP bytes
 * @returns {Float32Array} 64 * 13 class probabilities
 */
export function classify(model, crops) {
  const n = crops.length / (CROP * CROP);
  const nc = CLASSES.length;
  const probs = new Float32Array(n * nc);
  for (let s = 0; s < n; s++) {
    let x = new Float32Array(CROP * CROP);
    const base = s * CROP * CROP;
    for (let k = 0; k < x.length; k++) x[k] = crops[base + k] / 255 - 0.5;
    let channels = 1;
    let size = CROP;
    for (const layer of model.layers) {
      if (layer.type === 'conv') {
        x = conv3(x, channels, size, layer.w, layer.b);
        channels = layer.w.shape[0];
      } else if (layer.type === 'pool') {
        x = pool2(x, channels, size);
        size >>= 1;
      } else if (layer.type === 'dense') {
        x = dense(x, layer.w, layer.b, layer.relu);
      }
    }
    let max = -Infinity;
    for (let k = 0; k < nc; k++) if (x[k] > max) max = x[k];
    let sum = 0;
    for (let k = 0; k < nc; k++) sum += Math.exp(x[k] - max);
    for (let k = 0; k < nc; k++) probs[s * nc + k] = Math.exp(x[k] - max) / sum;
  }
  return probs;
}
