// Fits a projective square lattice to corner candidates: lattice (i, j) -> image (x, y).

/** Solve A x = b in place (Gaussian elimination, partial pivoting). Returns null when singular. */
function solve(A, b) {
  const n = b.length;
  for (let c = 0; c < n; c++) {
    let piv = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(A[r][c]) > Math.abs(A[piv][c])) piv = r;
    if (Math.abs(A[piv][c]) < 1e-12) return null;
    if (piv !== c) {
      [A[piv], A[c]] = [A[c], A[piv]];
      [b[piv], b[c]] = [b[c], b[piv]];
    }
    for (let r = c + 1; r < n; r++) {
      const f = A[r][c] / A[c][c];
      if (f === 0) continue;
      for (let k = c; k < n; k++) A[r][k] -= f * A[c][k];
      b[r] -= f * b[c];
    }
  }
  const x = new Array(n);
  for (let r = n - 1; r >= 0; r--) {
    let s = b[r];
    for (let k = r + 1; k < n; k++) s -= A[r][k] * x[k];
    x[r] = s / A[r][r];
  }
  return x;
}

function normalizer(pts) {
  let cx = 0, cy = 0;
  for (const [x, y] of pts) {
    cx += x;
    cy += y;
  }
  cx /= pts.length;
  cy /= pts.length;
  let d = 0;
  for (const [x, y] of pts) d += Math.hypot(x - cx, y - cy);
  d /= pts.length;
  const s = d > 1e-9 ? Math.SQRT2 / d : 1;
  return { s, cx, cy };
}

/**
 * Least-squares homography mapping src[k] -> dst[k] (arrays of [x, y]); needs >= 4 pairs.
 * Returns a 9-element row-major matrix or null.
 */
export function fitHomography(src, dst) {
  const n = src.length;
  if (n < 4) return null;
  const ns = normalizer(src);
  const nd = normalizer(dst);
  const AtA = Array.from({ length: 8 }, () => new Array(8).fill(0));
  const Atb = new Array(8).fill(0);
  const row = new Array(8);
  const add = (r, rhs) => {
    for (let a = 0; a < 8; a++) {
      if (r[a] === 0) continue;
      Atb[a] += r[a] * rhs;
      for (let c = 0; c < 8; c++) AtA[a][c] += r[a] * r[c];
    }
  };
  for (let k = 0; k < n; k++) {
    const x = (src[k][0] - ns.cx) * ns.s;
    const y = (src[k][1] - ns.cy) * ns.s;
    const u = (dst[k][0] - nd.cx) * nd.s;
    const v = (dst[k][1] - nd.cy) * nd.s;
    row[0] = x; row[1] = y; row[2] = 1; row[3] = 0; row[4] = 0; row[5] = 0; row[6] = -u * x; row[7] = -u * y;
    add(row, u);
    row[0] = 0; row[1] = 0; row[2] = 0; row[3] = x; row[4] = y; row[5] = 1; row[6] = -v * x; row[7] = -v * y;
    add(row, v);
  }
  const h = solve(AtA, Atb);
  if (!h) return null;
  // Denormalise: H = Td^-1 * Hn * Ts
  const Hn = [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1];
  const Ts = [ns.s, 0, -ns.s * ns.cx, 0, ns.s, -ns.s * ns.cy, 0, 0, 1];
  const TdInv = [1 / nd.s, 0, nd.cx, 0, 1 / nd.s, nd.cy, 0, 0, 1];
  return mul(TdInv, mul(Hn, Ts));
}

export function mul(a, b) {
  const o = new Array(9);
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      o[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
    }
  }
  return o;
}

export function invert(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h;
  const B = -(d * i - f * g);
  const C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-14) return null;
  const s = 1 / det;
  return [
    A * s, -(b * i - c * h) * s, (b * f - c * e) * s,
    B * s, (a * i - c * g) * s, -(a * f - c * d) * s,
    C * s, -(a * h - b * g) * s, (a * e - b * d) * s,
  ];
}

export function apply(H, x, y) {
  const w = H[6] * x + H[7] * y + H[8];
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w];
}

/** Assign points to integer lattice nodes under H; one point per node, nearest wins. */
function match(points, Hinv, radius, tol) {
  const best = new Map();
  for (let k = 0; k < points.length; k++) {
    const p = points[k];
    const w = Hinv[6] * p.x + Hinv[7] * p.y + Hinv[8];
    if (Math.abs(w) < 1e-9) continue;
    const u = (Hinv[0] * p.x + Hinv[1] * p.y + Hinv[2]) / w;
    const v = (Hinv[3] * p.x + Hinv[4] * p.y + Hinv[5]) / w;
    const i = Math.round(u);
    const j = Math.round(v);
    if (Math.abs(i) > radius || Math.abs(j) > radius) continue;
    const err = Math.hypot(u - i, v - j);
    if (err > tol) continue;
    const key = i * 64 + j;
    const prev = best.get(key);
    if (!prev || err < prev.err) best.set(key, { i, j, k, err });
  }
  return [...best.values()];
}

function grow(points, H0) {
  let H = H0;
  let inliers = [];
  for (const radius of [1, 2, 2, 3, 4, 5, 7, 9, 9]) {
    const Hinv = invert(H);
    if (!Hinv) return null;
    const m = match(points, Hinv, radius, radius >= 9 ? 0.14 : 0.2);
    if (m.length < 4) return null;
    const Hn = fitHomography(m.map((q) => [q.i, q.j]), m.map((q) => [points[q.k].x, points[q.k].y]));
    if (!Hn) return null;
    H = Hn;
    inliers = m;
  }
  return { H, inliers };
}

function spanOf(inliers) {
  let i0 = Infinity, i1 = -Infinity, j0 = Infinity, j1 = -Infinity;
  for (const q of inliers) {
    if (q.i < i0) i0 = q.i;
    if (q.i > i1) i1 = q.i;
    if (q.j < j0) j0 = q.j;
    if (q.j > j1) j1 = q.j;
  }
  return { i0, i1, j0, j1 };
}

/**
 * @param {{x:number,y:number,strength:number}[]} points strongest first
 * @returns {{H:number[], inliers:{i:number,j:number,k:number}[], span:{i0,i1,j0,j1}}|null}
 *   H maps lattice coordinates to image coordinates, with the i axis pointing right and j down.
 */
export function fitLattice(points, { maxSeeds = 80 } = {}) {
  const n = points.length;
  if (n < 16) return null;
  let best = null;
  const tried = new Set();

  for (let s = 0; s < Math.min(n, maxSeeds); s++) {
    const p = points[s];
    // Five nearest neighbours of the seed.
    const near = [];
    for (let k = 0; k < n; k++) {
      if (k === s) continue;
      const d = (points[k].x - p.x) ** 2 + (points[k].y - p.y) ** 2;
      if (near.length < 5) {
        near.push({ k, d });
        near.sort((a, b) => a.d - b.d);
      } else if (d < near[4].d) {
        near[4] = { k, d };
        near.sort((a, b) => a.d - b.d);
      }
    }
    for (let a = 0; a < near.length; a++) {
      for (let b = a + 1; b < near.length; b++) {
        const qa = points[near[a].k];
        const qb = points[near[b].k];
        const ax = qa.x - p.x, ay = qa.y - p.y;
        const bx = qb.x - p.x, by = qb.y - p.y;
        const la = Math.hypot(ax, ay), lb = Math.hypot(bx, by);
        if (la < 6 || lb < 6) continue;
        const ratio = la / lb;
        if (ratio < 0.5 || ratio > 2) continue;
        const cos = (ax * bx + ay * by) / (la * lb);
        if (Math.abs(cos) > 0.7) continue;
        // The fourth corner of the cell must exist too.
        const fx = p.x + ax + bx, fy = p.y + ay + by;
        const tol = 0.3 * Math.min(la, lb);
        let fourth = -1;
        let fd = tol * tol;
        for (let k = 0; k < n; k++) {
          const d = (points[k].x - fx) ** 2 + (points[k].y - fy) ** 2;
          if (d < fd) {
            fd = d;
            fourth = k;
          }
        }
        if (fourth < 0) continue;
        const key = [s, near[a].k, near[b].k, fourth].sort((x, y) => x - y).join(',');
        if (tried.has(key)) continue;
        tried.add(key);
        const H0 = fitHomography(
          [[0, 0], [1, 0], [0, 1], [1, 1]],
          [[p.x, p.y], [qa.x, qa.y], [qb.x, qb.y], [points[fourth].x, points[fourth].y]],
        );
        if (!H0) continue;
        const g = grow(points, H0);
        if (!g) continue;
        const span = spanOf(g.inliers);
        if (span.i1 - span.i0 < 3 || span.j1 - span.j0 < 3) continue;
        let err = 0;
        for (const q of g.inliers) err += q.err;
        // A lattice at the wrong pitch (half squares) or one that strays into clutter leaves holes;
        // weight the inlier count by how completely the spanned block is filled.
        const fill = g.inliers.length / ((span.i1 - span.i0 + 1) * (span.j1 - span.j0 + 1));
        const score = g.inliers.length * fill - err / g.inliers.length;
        if (!best || score > best.score) best = { ...g, span, score };
      }
    }
  }
  if (!best || best.inliers.length < 16) return null;
  return canonicalize(points, best);
}

/** Re-index the lattice so that i runs left-to-right and j top-to-bottom in the image. */
function canonicalize(points, fit) {
  const { span } = fit;
  const ci = (span.i0 + span.i1) / 2;
  const cj = (span.j0 + span.j1) / 2;
  const o = apply(fit.H, ci, cj);
  const pi = apply(fit.H, ci + 1, cj);
  const pj = apply(fit.H, ci, cj + 1);
  let vi = [pi[0] - o[0], pi[1] - o[1]];
  let vj = [pj[0] - o[0], pj[1] - o[1]];
  let swap = false;
  if (Math.abs(vi[0]) < Math.abs(vj[0])) {
    swap = true;
    [vi, vj] = [vj, vi];
  }
  const si = vi[0] < 0 ? -1 : 1;
  const sj = vj[1] < 0 ? -1 : 1;
  const inliers = fit.inliers.map((q) => {
    const a = swap ? q.j : q.i;
    const b = swap ? q.i : q.j;
    return { i: si * a, j: sj * b, k: q.k };
  });
  const H = fitHomography(inliers.map((q) => [q.i, q.j]), inliers.map((q) => [points[q.k].x, points[q.k].y]));
  if (!H) return null;
  return { H, inliers, span: spanOf(inliers) };
}

/**
 * Refit using only the corners that belong to the board's 7x7 inner lattice, tightening the
 * tolerance each round so that stray matches (piece artwork, text) stop bending the fit.
 * @param {number} a window origin: inner corners are at a+1..a+7, b+1..b+7
 */
export function refine(points, H, a, b) {
  let current = H;
  for (const tol of [0.14, 0.09, 0.06]) {
    const Hinv = invert(current);
    if (!Hinv) break;
    const m = match(points, Hinv, 64, tol).filter((q) => q.i > a && q.i < a + 8 && q.j > b && q.j < b + 8);
    if (m.length < 12) break;
    const next = fitHomography(m.map((q) => [q.i, q.j]), m.map((q) => [points[q.k].x, points[q.k].y]));
    if (!next) break;
    current = next;
  }
  return current;
}
