// Board drawing shared by the page, the saved list and the image sent to the glasses.
const FILES = { P: 'wP', N: 'wN', B: 'wB', R: 'wR', Q: 'wQ', K: 'wK', p: 'bP', n: 'bN', b: 'bB', r: 'bR', q: 'bQ', k: 'bK' };

export const PIECES = Object.keys(FILES);
export const pieceUrl = (letter) => `pieces/${FILES[letter]}.svg`;

export const THEMES = {
  page: { light: '#ecd9b9', dark: '#ae8a68' },
  // The lens adds light to the world: black is transparent, so squares stay bright enough for
  // black pieces to read as silhouettes.
  lens: { light: '#f2f2f2', dark: '#8c8c8c' },
};

let images = null;

export function loadPieceImages() {
  if (!images) {
    images = Promise.all(
      PIECES.map(
        (letter) =>
          new Promise((resolve, reject) => {
            const img = new Image();
            img.onload = () => resolve([letter, img]);
            img.onerror = () => reject(new Error(`could not load ${pieceUrl(letter)}`));
            img.src = pieceUrl(letter);
          }),
      ),
    ).then((entries) => new Map(entries));
  }
  return images;
}

/** Which cell a visual square shows. `viewFlipped` draws the board from Black's side. */
export const cellAt = (visualIndex, viewFlipped) => (viewFlipped ? 63 - visualIndex : visualIndex);

export function drawBoard(canvas, cells, pieceImages, { size = 320, viewFlipped = false, theme = THEMES.page } = {}) {
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  const sq = size / 8;
  for (let v = 0; v < 64; v++) {
    const r = Math.floor(v / 8);
    const c = v % 8;
    ctx.fillStyle = (r + c) % 2 === 0 ? theme.light : theme.dark;
    ctx.fillRect(c * sq, r * sq, sq, sq);
    const piece = cells[cellAt(v, viewFlipped)];
    if (piece) ctx.drawImage(pieceImages.get(piece), c * sq, r * sq, sq, sq);
  }
  return canvas;
}

/** PNG of the board as base64 without the data: prefix. */
export function boardPng(cells, pieceImages, options) {
  const canvas = drawBoard(document.createElement('canvas'), cells, pieceImages, options);
  return canvas.toDataURL('image/png').split(',')[1];
}
