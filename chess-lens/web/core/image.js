// Small grayscale image helpers. Images are { data: Float32Array, width, height } with values 0..255.

/** RGBA bytes -> luma. */
export function toGray(rgba, width, height) {
  const out = new Float32Array(width * height);
  for (let i = 0, p = 0; i < out.length; i++, p += 4) {
    out[i] = 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
  }
  return { data: out, width, height };
}

/** Area-average downscale (any ratio >= 1). Returns the source untouched when no shrink is needed. */
export function shrink(img, targetW, targetH) {
  const { data, width, height } = img;
  if (targetW >= width && targetH >= height) return img;
  const out = new Float32Array(targetW * targetH);
  const sx = width / targetW;
  const sy = height / targetH;
  for (let y = 0; y < targetH; y++) {
    const y0 = y * sy;
    const y1 = Math.min(height, (y + 1) * sy);
    const iy0 = Math.floor(y0);
    const iy1 = Math.min(height, Math.ceil(y1));
    for (let x = 0; x < targetW; x++) {
      const x0 = x * sx;
      const x1 = Math.min(width, (x + 1) * sx);
      const ix0 = Math.floor(x0);
      const ix1 = Math.min(width, Math.ceil(x1));
      let sum = 0;
      let area = 0;
      for (let yy = iy0; yy < iy1; yy++) {
        const wy = Math.min(yy + 1, y1) - Math.max(yy, y0);
        const row = yy * width;
        for (let xx = ix0; xx < ix1; xx++) {
          const w = wy * (Math.min(xx + 1, x1) - Math.max(xx, x0));
          sum += w * data[row + xx];
          area += w;
        }
      }
      out[y * targetW + x] = area > 0 ? sum / area : 0;
    }
  }
  return { data: out, width: targetW, height: targetH };
}

/** Separable Gaussian blur with edge clamping. */
export function blur(img, sigma) {
  if (sigma <= 0) return img;
  const { data, width, height } = img;
  const radius = Math.max(1, Math.ceil(sigma * 2.5));
  const kernel = new Float32Array(radius * 2 + 1);
  let norm = 0;
  for (let i = -radius; i <= radius; i++) {
    const v = Math.exp(-(i * i) / (2 * sigma * sigma));
    kernel[i + radius] = v;
    norm += v;
  }
  for (let i = 0; i < kernel.length; i++) kernel[i] /= norm;

  const tmp = new Float32Array(data.length);
  for (let y = 0; y < height; y++) {
    const row = y * width;
    for (let x = 0; x < width; x++) {
      let s = 0;
      for (let k = -radius; k <= radius; k++) {
        const xx = x + k < 0 ? 0 : x + k >= width ? width - 1 : x + k;
        s += kernel[k + radius] * data[row + xx];
      }
      tmp[row + x] = s;
    }
  }
  const out = new Float32Array(data.length);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let s = 0;
      for (let k = -radius; k <= radius; k++) {
        const yy = y + k < 0 ? 0 : y + k >= height ? height - 1 : y + k;
        s += kernel[k + radius] * tmp[yy * width + x];
      }
      out[y * width + x] = s;
    }
  }
  return { data: out, width, height };
}

/** Bilinear sample with edge clamping. (x, y) address pixel centres at integer coordinates. */
export function sample(img, x, y) {
  const { data, width, height } = img;
  if (x < 0) x = 0;
  else if (x > width - 1) x = width - 1;
  if (y < 0) y = 0;
  else if (y > height - 1) y = height - 1;
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const x1 = x0 + 1 < width ? x0 + 1 : x0;
  const y1 = y0 + 1 < height ? y0 + 1 : y0;
  const fx = x - x0;
  const fy = y - y0;
  const a = data[y0 * width + x0];
  const b = data[y0 * width + x1];
  const c = data[y1 * width + x0];
  const d = data[y1 * width + x1];
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

export function inside(img, x, y, margin = 0) {
  return x >= margin && y >= margin && x <= img.width - 1 - margin && y <= img.height - 1 - margin;
}
