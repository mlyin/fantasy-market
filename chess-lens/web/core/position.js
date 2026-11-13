// Turns per-square class probabilities into a position: orientation, king repair, FEN.
import { CLASSES } from './classifier.js';

const NC = CLASSES.length;
const K_WHITE = CLASSES.indexOf('K');
const K_BLACK = CLASSES.indexOf('k');

/** Rotate a 64-entry row-major array by 180 degrees. */
export function rotate180(cells) {
  return cells.slice().reverse();
}

/** Rotate a 64-entry row-major array a quarter turn clockwise. */
export function rotate90(cells) {
  const out = new Array(64);
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) out[c * 8 + (7 - r)] = cells[r * 8 + c];
  return out;
}

/**
 * Most likely piece per square, then repair king counts: a legal position has exactly one king a
 * side, so surplus kings fall back to their second choice and a missing king is taken from the
 * square that most resembles one.
 * @param {Float32Array} probs 64 * 13
 * @param {{materialPrior?: boolean}} [options] set false to skip the material-count check
 * @returns {{cells: string[], confidence: number[]}} cells use '' for empty and FEN letters
 */
export function decode(probs, { materialPrior = true } = {}) {
  const idx = new Array(64);
  const confidence = new Array(64);
  for (let s = 0; s < 64; s++) {
    let best = 0;
    for (let k = 1; k < NC; k++) if (probs[s * NC + k] > probs[s * NC + best]) best = k;
    idx[s] = best;
    confidence[s] = probs[s * NC + best];
  }
  for (const king of [K_WHITE, K_BLACK]) {
    const have = [];
    for (let s = 0; s < 64; s++) if (idx[s] === king) have.push(s);
    if (have.length > 1) {
      have.sort((a, b) => probs[b * NC + king] - probs[a * NC + king]);
      for (const s of have.slice(1)) {
        let second = 0;
        let sp = -1;
        for (let k = 0; k < NC; k++) {
          if (k === K_WHITE || k === K_BLACK) continue;
          if (probs[s * NC + k] > sp) {
            sp = probs[s * NC + k];
            second = k;
          }
        }
        idx[s] = second;
        confidence[s] = Math.min(sp, 0.5);
      }
    } else if (have.length === 0) {
      let at = -1;
      let p = 0.02; // do not invent a king out of nothing
      for (let s = 0; s < 64; s++) {
        if (idx[s] === K_WHITE || idx[s] === K_BLACK || idx[s] === 0) continue;
        if (probs[s * NC + king] > p) {
          p = probs[s * NC + king];
          at = s;
        }
      }
      if (at >= 0) {
        idx[at] = king;
        confidence[at] = Math.min(p, 0.5);
      }
    }
  }
  if (materialPrior) applyMaterialLimits(idx, confidence, probs);
  return { cells: idx.map((k) => CLASSES[k]), confidence };
}

// What one side starts with. More of a piece than this needs a promotion, which is rare in the
// positions people study; more than eight pawns is impossible.
const START_COUNTS = { P: 8, N: 2, B: 2, R: 2, Q: 1 };
// A surplus piece is only re-read when its second choice was at least this likely relative to
// its first. A confident reading (a real third bishop) stays.
const DOUBT_RATIO = 0.03;

/**
 * An unfamiliar piece set can make one piece type look like another across the whole board
 * (a tall pawn read as a bishop on all eight squares). Material counts catch that: while a side
 * has more of a piece than it started with, the least certain of them falls back to its next
 * most likely reading that does not itself break a limit.
 */
function applyMaterialLimits(idx, confidence, probs) {
  for (const white of [true, false]) {
    const cls = (letter) => CLASSES.indexOf(white ? letter : letter.toLowerCase());
    const limits = new Map(Object.entries(START_COUNTS).map(([letter, n]) => [cls(letter), n]));
    const count = (k) => idx.reduce((n, v) => n + (v === k ? 1 : 0), 0);
    for (let guard = 0; guard < 64; guard++) {
      let change = null;
      for (const [k, limit] of limits) {
        if (count(k) <= limit) continue;
        for (let s = 0; s < 64; s++) {
          if (idx[s] !== k) continue;
          // Best alternative for this square: empty or a piece of the same colour with room left.
          let alt = -1;
          for (let c = 0; c < NC; c++) {
            if (c === k || c === K_WHITE || c === K_BLACK) continue;
            if (c !== 0 && (!limits.has(c) || count(c) >= limits.get(c))) continue;
            if (alt < 0 || probs[s * NC + c] > probs[s * NC + alt]) alt = c;
          }
          if (alt < 0) continue;
          const ratio = probs[s * NC + alt] / Math.max(1e-9, probs[s * NC + k]);
          if (ratio >= DOUBT_RATIO && (!change || ratio > change.ratio)) change = { s, alt, ratio };
        }
      }
      if (!change) break;
      idx[change.s] = change.alt;
      confidence[change.s] = Math.min(probs[change.s * NC + change.alt], 0.5);
    }
  }
}

/**
 * Guess whether the diagram is drawn from Black's side. Pawns only move forward, so White's pawns
 * sit lower on a normally oriented board than Black's; kings break ties.
 */
export function looksFlipped(cells) {
  const meanRow = (letter) => {
    let sum = 0, n = 0;
    for (let s = 0; s < 64; s++) {
      if (cells[s] === letter) {
        sum += Math.floor(s / 8);
        n++;
      }
    }
    return n ? sum / n : null;
  };
  let wp = meanRow('P');
  let bp = meanRow('p');
  if (wp !== null && bp !== null && Math.abs(wp - bp) >= 0.75) return wp < bp;
  // No usable pawn evidence: kings usually stay on their own half.
  const wk = meanRow('K');
  const bk = meanRow('k');
  if (wk !== null && bk !== null && Math.abs(wk - bk) >= 2) return wk < bk;
  return false;
}

/** @param {string[]} cells row-major from a8 @returns {string} FEN piece placement */
export function placementOf(cells) {
  const rows = [];
  for (let r = 0; r < 8; r++) {
    let row = '';
    let gap = 0;
    for (let c = 0; c < 8; c++) {
      const p = cells[r * 8 + c];
      if (!p) gap++;
      else {
        if (gap) row += gap;
        gap = 0;
        row += p;
      }
    }
    if (gap) row += gap;
    rows.push(row);
  }
  return rows.join('/');
}

/** Castling rights that the piece layout still allows (king and rook on their home squares). */
export function castlingOf(cells) {
  let rights = '';
  if (cells[60] === 'K') {
    if (cells[63] === 'R') rights += 'K';
    if (cells[56] === 'R') rights += 'Q';
  }
  if (cells[4] === 'k') {
    if (cells[7] === 'r') rights += 'k';
    if (cells[0] === 'r') rights += 'q';
  }
  return rights || '-';
}

export function fenOf(cells, turn = 'w') {
  return `${placementOf(cells)} ${turn} ${castlingOf(cells)} - 0 1`;
}

/** @param {string} fen @returns {string[]} 64 cells, or null when the placement is malformed */
export function cellsOf(fen) {
  const rows = fen.trim().split(/\s+/)[0].split('/');
  if (rows.length !== 8) return null;
  const cells = [];
  for (const row of rows) {
    let n = 0;
    for (const ch of row) {
      if (ch >= '1' && ch <= '8') {
        for (let k = 0; k < Number(ch); k++) cells.push('');
        n += Number(ch);
      } else if ('PNBRQKpnbrqk'.includes(ch)) {
        cells.push(ch);
        n++;
      } else return null;
    }
    if (n !== 8) return null;
  }
  return cells;
}

/** Things a scan can get wrong that a person should look at before trusting the position. */
export function problemsOf(cells) {
  const count = (l) => cells.filter((c) => c === l).length;
  const problems = [];
  if (count('K') !== 1) problems.push(count('K') === 0 ? 'No white king' : 'More than one white king');
  if (count('k') !== 1) problems.push(count('k') === 0 ? 'No black king' : 'More than one black king');
  for (let c = 0; c < 8; c++) {
    if (/[Pp]/.test(cells[c]) || /[Pp]/.test(cells[56 + c])) {
      problems.push('Pawn on the first or last rank');
      break;
    }
  }
  if (count('P') > 8 || count('p') > 8) problems.push('More than eight pawns on one side');
  const white = cells.filter((c) => c && c === c.toUpperCase()).length;
  const black = cells.filter((c) => c && c === c.toLowerCase()).length;
  if (white > 16 || black > 16) problems.push('More than sixteen pieces on one side');
  return problems;
}

export function describe(cells, turn = 'w') {
  const n = cells.filter(Boolean).length;
  return `${turn === 'w' ? 'White' : 'Black'} to move · ${n} piece${n === 1 ? '' : 's'}`;
}
