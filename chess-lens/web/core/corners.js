// ChESS corner detector (Bennett & Lasenby, "ChESS - Quick and robust detection of chess-board
// features", 2014). It responds to the X-shaped junction where four squares meet and stays quiet on
// plain edges, text and piece artwork, which is what makes the lattice fit in lattice.js tractable.

const RING = [
  [0, -5], [2, -5], [3, -3], [5, -2], [5, 0], [5, 2], [3, 3], [2, 5],
  [0, 5], [-2, 5], [-3, 3], [-5, 2], [-5, 0], [-5, -2], [-3, -3], [-2, -5],
];
const BORDER = 7;

/**
 * @param {{data: Float32Array, width: number, height: number}} img lightly blurred grayscale image
 * @returns {{x: number, y: number, strength: number}[]} every sub-pixel corner candidate, strongest first
 */
export function findCorners(img, { nmsRadius = 4 } = {}) {
  const { data, width, height } = img;
  const response = new Float32Array(width * height);
  const offs = RING.map(([dx, dy]) => dy * width + dx);

  for (let y = BORDER; y < height - BORDER; y++) {
    for (let x = BORDER; x < width - BORDER; x++) {
      const p = y * width + x;
      const r0 = data[p + offs[0]], r1 = data[p + offs[1]], r2 = data[p + offs[2]], r3 = data[p + offs[3]];
      const r4 = data[p + offs[4]], r5 = data[p + offs[5]], r6 = data[p + offs[6]], r7 = data[p + offs[7]];
      const r8 = data[p + offs[8]], r9 = data[p + offs[9]], r10 = data[p + offs[10]], r11 = data[p + offs[11]];
      const r12 = data[p + offs[12]], r13 = data[p + offs[13]], r14 = data[p + offs[14]], r15 = data[p + offs[15]];
      // Sum response: opposite samples agree, samples a quarter turn apart disagree.
      const sr =
        Math.abs(r0 + r8 - r4 - r12) + Math.abs(r1 + r9 - r5 - r13) +
        Math.abs(r2 + r10 - r6 - r14) + Math.abs(r3 + r11 - r7 - r15);
      if (sr < 8) continue;
      // Diff response: plain edges make opposite samples differ.
      const dr =
        Math.abs(r0 - r8) + Math.abs(r1 - r9) + Math.abs(r2 - r10) + Math.abs(r3 - r11) +
        Math.abs(r4 - r12) + Math.abs(r5 - r13) + Math.abs(r6 - r14) + Math.abs(r7 - r15);
      // Mean response: stripes make the ring mean differ from the local mean.
      const ringMean = (r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7 + r8 + r9 + r10 + r11 + r12 + r13 + r14 + r15) / 16;
      const localMean = (data[p] + data[p - 1] + data[p + 1] + data[p - width] + data[p + width]) / 5;
      const r = sr - dr - 16 * Math.abs(ringMean - localMean);
      if (r > 0) response[p] = r;
    }
  }

  const peaks = [];
  for (let y = BORDER; y < height - BORDER; y++) {
    for (let x = BORDER; x < width - BORDER; x++) {
      const p = y * width + x;
      const v = response[p];
      if (v <= 0) continue;
      let isMax = true;
      for (let dy = -nmsRadius; dy <= nmsRadius && isMax; dy++) {
        const row = p + dy * width;
        for (let dx = -nmsRadius; dx <= nmsRadius; dx++) {
          const o = response[row + dx];
          if (o > v || (o === v && (dy < 0 || (dy === 0 && dx < 0)))) {
            isMax = false;
            break;
          }
        }
      }
      if (!isMax) continue;
      // Sub-pixel position: response-weighted centroid of the 5x5 neighbourhood.
      let sw = 0, sx = 0, sy = 0;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          const w = response[p + dy * width + dx];
          sw += w;
          sx += w * dx;
          sy += w * dy;
        }
      }
      peaks.push({ x: x + sx / sw, y: y + sy / sw, strength: sw });
    }
  }
  peaks.sort((a, b) => b.strength - a.strength);
  return peaks.slice(0, 3000);
}

/**
 * The corners worth fitting a lattice to. A board contributes 49 strong corners, so anything far
 * weaker than the ~20th strongest is clutter. Calling this again after removing one board's
 * corners re-calibrates the cut-off for a fainter second diagram.
 * @param {{x: number, y: number, strength: number}[]} peaks strongest first
 */
export function strongCorners(peaks, { maxCorners = 700 } = {}) {
  if (peaks.length === 0) return peaks;
  const ref = peaks[Math.min(19, peaks.length - 1)].strength;
  return peaks.filter((p) => p.strength >= ref * 0.12).slice(0, maxCorners);
}
