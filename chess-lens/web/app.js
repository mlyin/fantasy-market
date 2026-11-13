import { scan, loadModel } from './core/scan.js';
import { rotate180, rotate90, fenOf, cellsOf, problemsOf, describe } from './core/position.js';
import { native } from './native.js';
import { loadSaved, writeSaved } from './store.js';
import { PIECES, pieceUrl, THEMES, loadPieceImages, drawBoard, boardPng, cellAt } from './render.js';

const $ = (id) => document.getElementById(id);
// Longest image side handed to the scanner. Glasses photos are wide-angle, so a diagram can be a
// small part of a 12-megapixel frame; keep enough pixels for its squares to stay readable.
const MAX_SIDE = 3200;

const state = {
  model: null,
  pieceImages: null,
  stream: null,
  glasses: null, // last status message from the shell
  cells: null, // 64 entries from a8, '' for empty
  unsure: new Set(),
  turn: 'w',
  viewFlipped: false,
  selected: null, // cell index
  saved: loadSaved(),
};

/* ---------- views ---------- */

function show(view) {
  for (const name of ['capture', 'result', 'saved']) $(`view-${name}`).hidden = name !== view;
  window.scrollTo(0, 0);
}

function notice(el, text, isError = false) {
  el.hidden = !text;
  el.textContent = text || '';
  el.classList.toggle('error', isError);
}

async function busy(text, work) {
  $('busy-text').textContent = text;
  $('busy').hidden = false;
  // Let the overlay paint before the scanner blocks the thread.
  await new Promise((resolve) => setTimeout(resolve, 30));
  try {
    return await work();
  } finally {
    $('busy').hidden = true;
  }
}

/* ---------- pixels ---------- */

function toCanvas(source, width, height) {
  const scale = Math.min(1, MAX_SIDE / Math.max(width, height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  canvas.getContext('2d', { willReadFrequently: true }).drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}

async function canvasFromBlob(blob) {
  const url = URL.createObjectURL(blob);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return toCanvas(img, img.naturalWidth, img.naturalHeight);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/* ---------- scanning ---------- */

/** @returns the scan result, after showing it (or the failure) on the page. */
async function scanCanvas(canvas) {
  if (!state.model) {
    notice($('capture-notice'), 'The recogniser is still loading. Try again in a moment.', true);
    return { ok: false, message: 'Recogniser not loaded' };
  }
  const result = await busy('Scanning…', () => {
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    return scan(state.model, ctx.getImageData(0, 0, canvas.width, canvas.height));
  });
  if (!result.ok) {
    show('capture');
    notice($('capture-notice'), result.message, true);
    return result;
  }
  notice($('capture-notice'), '');
  state.cells = result.cells;
  state.unsure = new Set(result.unsure);
  state.turn = 'w';
  state.viewFlipped = result.flipped;
  state.selected = null;
  drawSource(canvas, result.quad);
  renderResult();
  show('result');
  return result;
}

function drawSource(canvas, quad) {
  const out = $('source-canvas');
  const scale = Math.min(1, 900 / Math.max(canvas.width, canvas.height));
  out.width = Math.round(canvas.width * scale);
  out.height = Math.round(canvas.height * scale);
  const ctx = out.getContext('2d');
  ctx.drawImage(canvas, 0, 0, out.width, out.height);
  ctx.beginPath();
  quad.forEach(([x, y], i) => (i ? ctx.lineTo(x * scale, y * scale) : ctx.moveTo(x * scale, y * scale)));
  ctx.closePath();
  ctx.lineWidth = Math.max(2, out.width / 250);
  ctx.strokeStyle = '#e9b44c';
  ctx.stroke();
  // Useful when judging a camera: a board needs roughly 100 px across to be read reliably.
  const across = Math.hypot(quad[1][0] - quad[0][0], quad[1][1] - quad[0][1]);
  $('source-info').textContent = `Photo ${canvas.width} × ${canvas.height} px · board about ${Math.round(across)} px across`;
}

async function scanBlob(blob) {
  let canvas;
  try {
    canvas = await canvasFromBlob(blob);
  } catch {
    notice($('capture-notice'), 'That file could not be opened as a picture.', true);
    return { ok: false, message: 'Unreadable image' };
  }
  return scanCanvas(canvas);
}

async function scanUrl(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return scanBlob(await response.blob());
}

/* ---------- result view ---------- */

const squareName = (cell) => 'abcdefgh'[cell % 8] + (8 - Math.floor(cell / 8));
const PIECE_NAMES = { P: 'white pawn', N: 'white knight', B: 'white bishop', R: 'white rook', Q: 'white queen', K: 'white king', p: 'black pawn', n: 'black knight', b: 'black bishop', r: 'black rook', q: 'black queen', k: 'black king' };

function renderBoard() {
  const board = $('board');
  board.textContent = '';
  for (let v = 0; v < 64; v++) {
    const cell = cellAt(v, state.viewFlipped);
    const r = Math.floor(v / 8);
    const c = v % 8;
    const piece = state.cells[cell];
    const sq = document.createElement('button');
    sq.type = 'button';
    sq.className = 'sq' + ((r + c) % 2 ? ' dark' : '');
    if (state.unsure.has(cell)) sq.classList.add('unsure');
    if (state.selected === cell) sq.classList.add('selected');
    sq.dataset.cell = String(cell);
    sq.setAttribute('aria-label', `${squareName(cell)}: ${piece ? PIECE_NAMES[piece] : 'empty'}${state.unsure.has(cell) ? ', uncertain' : ''}`);
    if (piece) {
      const img = document.createElement('img');
      img.src = pieceUrl(piece);
      img.alt = '';
      sq.append(img);
    }
    if (c === 0) sq.append(coord('rank', squareName(cell)[1]));
    if (r === 7) sq.append(coord('file', squareName(cell)[0]));
    board.append(sq);
  }
}

function coord(kind, text) {
  const span = document.createElement('span');
  span.className = `coord ${kind}`;
  span.textContent = text;
  return span;
}

function renderPalette() {
  const open = state.selected !== null;
  $('palette').hidden = !open;
  if (!open) return;
  const current = state.cells[state.selected];
  $('palette-label').textContent = `What is on ${squareName(state.selected)}?`;
  const grid = $('palette-grid');
  grid.textContent = '';
  const clear = document.createElement('button');
  clear.type = 'button';
  clear.className = 'clear';
  clear.textContent = 'Empty';
  clear.dataset.piece = '';
  clear.setAttribute('aria-pressed', String(!current));
  grid.append(clear);
  for (const letter of PIECES) {
    const b = document.createElement('button');
    b.type = 'button';
    b.dataset.piece = letter;
    b.setAttribute('aria-label', PIECE_NAMES[letter]);
    b.setAttribute('aria-pressed', String(current === letter));
    const img = document.createElement('img');
    img.src = pieceUrl(letter);
    img.alt = '';
    b.append(img);
    grid.append(b);
  }
}

function renderResult() {
  renderBoard();
  renderPalette();
  const fen = fenOf(state.cells, state.turn);
  $('fen').value = fen;
  $('lichess').href = `https://lichess.org/analysis/standard/${fen.replace(/ /g, '_')}`;
  $('turn-w').setAttribute('aria-pressed', String(state.turn === 'w'));
  $('turn-b').setAttribute('aria-pressed', String(state.turn === 'b'));

  const problems = problemsOf(state.cells);
  const parts = [];
  if (state.unsure.size > 12) {
    // That many doubtful squares means the picture was too small or blurred, or the outline is
    // off: fixing squares one by one is the wrong remedy.
    parts.push(`This scan looks unreliable (${state.unsure.size} uncertain squares). Check the outline on the photo below, or retake it closer and steadier.`);
  } else if (state.unsure.size) {
    parts.push(`${state.unsure.size} square${state.unsure.size === 1 ? ' is' : 's are'} uncertain (dashed outline). Tap a square to correct it.`);
  }
  if (problems.length) parts.push(`Check the position: ${problems.join('; ').toLowerCase()}.`);
  notice($('result-notice'), parts.join(' '), problems.length > 0 || state.unsure.size > 12);
}

function lensPayload() {
  return {
    fen: fenOf(state.cells, state.turn),
    boardPng: boardPng(state.cells, state.pieceImages, { size: 360, viewFlipped: state.viewFlipped, theme: THEMES.lens }),
    summary: describe(state.cells, state.turn),
  };
}

/** Tell the shell the position changed so the lens card follows the phone. */
function pushPosition() {
  if (native.available && state.cells) native.post({ type: 'position', ...lensPayload() });
}

function swapSides() {
  if (!state.cells) return;
  state.cells = rotate180(state.cells);
  state.unsure = new Set([...state.unsure].map((s) => 63 - s));
  if (state.selected !== null) state.selected = 63 - state.selected;
  state.viewFlipped = !state.viewFlipped;
  renderResult();
  pushPosition();
}

function quarterTurn() {
  if (!state.cells) return;
  const turned = (s) => (s % 8) * 8 + (7 - Math.floor(s / 8));
  state.cells = rotate90(state.cells);
  state.unsure = new Set([...state.unsure].map(turned));
  if (state.selected !== null) state.selected = turned(state.selected);
  renderResult();
  pushPosition();
}

/* ---------- saved ---------- */

function renderSavedCount() {
  $('saved-count').textContent = state.saved.length ? ` (${state.saved.length})` : '';
}

function renderSaved() {
  const list = $('saved-list');
  list.textContent = '';
  $('saved-empty').hidden = state.saved.length > 0;
  state.saved.forEach((entry, index) => {
    const cells = cellsOf(entry.fen);
    if (!cells) return;
    const li = document.createElement('li');
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'open';
    open.setAttribute('aria-label', `Open position saved ${new Date(entry.t).toLocaleString()}`);
    open.append(drawBoard(document.createElement('canvas'), cells, state.pieceImages, { size: 240, viewFlipped: Boolean(entry.flipped) }));
    open.addEventListener('click', () => {
      state.cells = cells;
      state.unsure = new Set();
      state.turn = entry.fen.split(' ')[1] === 'b' ? 'b' : 'w';
      state.viewFlipped = Boolean(entry.flipped);
      state.selected = null;
      $('source-details').hidden = true;
      renderResult();
      show('result');
      pushPosition();
    });
    const meta = document.createElement('div');
    meta.className = 'meta';
    const when = document.createElement('span');
    when.textContent = new Date(entry.t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'remove';
    remove.textContent = 'Delete';
    remove.addEventListener('click', () => {
      state.saved.splice(index, 1);
      writeSaved(state.saved);
      renderSaved();
      renderSavedCount();
    });
    meta.append(when, remove);
    li.append(open, meta);
    list.append(li);
  });
}

/* ---------- camera ---------- */

async function startCamera() {
  if (!navigator.mediaDevices?.getUserMedia) {
    notice($('capture-notice'), 'This browser cannot open the camera. Choose a photo instead.', true);
    return;
  }
  try {
    state.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
  } catch (err) {
    const denied = err?.name === 'NotAllowedError';
    notice($('capture-notice'), denied ? 'Camera access was declined. Allow it in settings, or choose a photo.' : 'No camera is available. Choose a photo instead.', true);
    return;
  }
  const video = $('video');
  video.srcObject = state.stream;
  await video.play().catch(() => {});
  notice($('capture-notice'), '');
  renderFinder();
}

const glassesLive = () => state.glasses?.session === 'started';

function renderFinder() {
  const live = glassesLive();
  const phone = Boolean(state.stream) && !live;
  $('video').hidden = !phone;
  $('glasses-frame').hidden = !(live && $('glasses-frame').src);
  $('finder-empty').hidden = phone || (live && Boolean($('glasses-frame').src));
  $('start-camera').hidden = live || Boolean(globalThis.CHESS_LENS_NO_LIVE_CAMERA);
  if (live) $('finder-message').textContent = 'Look at a chess diagram, then tap the button or pinch Scan in the lens.';
  else if (!globalThis.CHESS_LENS_NO_LIVE_CAMERA) $('finder-message').textContent = 'Point at a chess diagram in a book or on a screen.';
  $('finder-source').hidden = !(live || phone);
  $('finder-source').textContent = live ? 'Glasses' : 'Phone camera';
}

async function onShutter() {
  if (glassesLive()) {
    native.post({ type: 'capture' });
    return;
  }
  const video = $('video');
  if (state.stream && video.videoWidth) {
    await scanCanvas(toCanvas(video, video.videoWidth, video.videoHeight));
    return;
  }
  $('file').click();
}

/* ---------- glasses (iOS shell only) ---------- */

function renderGlasses() {
  const s = state.glasses;
  if (!s) return;
  const live = s.session === 'started';
  const connecting = s.session === 'starting' || s.registration === 'registering';
  const chip = $('glasses-chip');
  chip.textContent = live ? (s.deviceName ? `Connected · ${s.deviceName}` : 'Connected') : connecting ? 'Connecting…' : s.session === 'paused' ? 'Paused' : 'Not connected';
  chip.classList.toggle('on', live);
  $('glasses-detail').textContent = live
    ? s.hasDisplay
      ? 'Pinch Scan in the lens, or use the button above. Keep this app open on the phone: it does the reading.'
      : 'These glasses have no display, so results appear here. Keep this app open on the phone.'
    : 'Connect to scan what you are looking at and see the board in the lens.';
  notice($('glasses-error'), s.error || '', true);
  $('glasses-connect').textContent = live || connecting ? 'Disconnect' : 'Connect glasses';
  $('mock-toggle').checked = Boolean(s.mock);
  $('lens-preview').hidden = !(s.mock && live);
  if (!live) $('glasses-frame').removeAttribute('src');
  renderFinder();
}

async function onNativePhoto(message) {
  let result;
  try {
    result = await scanUrl(message.url);
  } catch (err) {
    console.error(err);
    result = { ok: false, message: 'The photo did not arrive from the glasses.' };
    notice($('capture-notice'), result.message, true);
  }
  if (result.ok) native.post({ type: 'scanResult', id: message.id, ok: true, ...lensPayload() });
  else native.post({ type: 'scanResult', id: message.id, ok: false, reason: result.message });
}

native.onMessage = (message) => {
  switch (message?.type) {
    case 'status':
      state.glasses = message;
      renderGlasses();
      break;
    case 'photo':
      onNativePhoto(message);
      break;
    case 'frame':
      if (glassesLive()) {
        $('glasses-frame').src = message.url;
        renderFinder();
      }
      break;
    case 'command':
      if (message.name === 'flip') swapSides();
      break;
  }
};

/* ---------- wiring ---------- */

$('scan').addEventListener('click', onShutter);
$('start-camera').addEventListener('click', startCamera);
$('file').addEventListener('change', async (event) => {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (file) await scanBlob(file);
});
$('try-sample').addEventListener('click', () =>
  scanUrl('samples/book-page.jpg').catch(() => notice($('capture-notice'), 'The sample picture is missing.', true)),
);

$('board').addEventListener('click', (event) => {
  const sq = event.target.closest('.sq');
  if (!sq) return;
  const cell = Number(sq.dataset.cell);
  state.selected = state.selected === cell ? null : cell;
  renderBoard();
  renderPalette();
});
$('palette-grid').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button || state.selected === null) return;
  state.cells[state.selected] = button.dataset.piece;
  state.unsure.delete(state.selected);
  state.selected = null;
  renderResult();
  pushPosition();
});
for (const turn of ['w', 'b']) {
  $(`turn-${turn}`).addEventListener('click', () => {
    state.turn = turn;
    renderResult();
    pushPosition();
  });
}
$('flip').addEventListener('click', swapSides);
$('rotate').addEventListener('click', quarterTurn);
$('copy-fen').addEventListener('click', async () => {
  const input = $('fen');
  try {
    await navigator.clipboard.writeText(input.value);
  } catch {
    input.select();
    document.execCommand('copy');
  }
  $('copy-fen').textContent = 'Copied';
  setTimeout(() => ($('copy-fen').textContent = 'Copy'), 1500);
});
$('save').addEventListener('click', () => {
  const fen = fenOf(state.cells, state.turn);
  state.saved = [{ fen, flipped: state.viewFlipped, t: Date.now() }, ...state.saved.filter((e) => e.fen !== fen)];
  const stored = writeSaved(state.saved);
  renderSavedCount();
  $('save').textContent = stored ? 'Saved' : 'Could not save';
  setTimeout(() => ($('save').textContent = 'Save'), 1500);
});
$('scan-again').addEventListener('click', () => {
  $('source-details').hidden = false;
  show('capture');
});
$('open-saved').addEventListener('click', () => {
  renderSaved();
  show('saved');
});
$('close-saved').addEventListener('click', () => show(state.cells ? 'result' : 'capture'));

$('glasses-connect').addEventListener('click', () => {
  const s = state.glasses;
  const active = s && (s.session === 'started' || s.session === 'starting' || s.registration === 'registering');
  native.post({ type: active ? 'disconnect' : 'connect' });
});
$('mock-toggle').addEventListener('change', (event) => native.post({ type: 'setMock', enabled: event.target.checked }));
let lensPreviewVisible = false;
$('lens-preview').addEventListener('click', () => {
  lensPreviewVisible = !lensPreviewVisible;
  $('lens-preview').textContent = lensPreviewVisible ? 'Hide lens preview' : 'Show lens preview';
  native.post({ type: 'lensPreview', visible: lensPreviewVisible });
});

async function init() {
  renderSavedCount();
  $('glasses-card').hidden = !native.available;
  // Some hosts (embedded previews) never allow a live camera; photos still work there.
  if (globalThis.CHESS_LENS_NO_LIVE_CAMERA) {
    $('start-camera').hidden = true;
    $('finder-message').textContent = 'Take or choose a photo of a chess diagram in a book or on a screen.';
  }
  try {
    const [manifest, weights, pieceImages] = await Promise.all([
      fetch('model/pieces-v1.json').then((r) => (r.ok ? r.json() : Promise.reject(new Error('model manifest missing')))),
      fetch('model/pieces-v1.bin').then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error('model weights missing')))),
      loadPieceImages(),
    ]);
    state.model = loadModel(manifest, weights);
    state.pieceImages = pieceImages;
  } catch (err) {
    console.error(err);
    notice($('capture-notice'), 'The recogniser failed to load. Reload the page to try again.', true);
  }
  native.post({ type: 'ready' });
  // Hosts that show the page before anyone has a photo to hand can open on the bundled example.
  if (globalThis.CHESS_LENS_OPEN_ON_SAMPLE && state.model) {
    const result = await scanUrl('samples/book-page.jpg').catch(() => null);
    if (result?.ok) {
      $('result-notice').hidden = false;
      $('result-notice').textContent = 'Example: this position was read from the sample photo below. Tap “Scan another” to try your own.';
      $('source-details').open = true;
    }
  }
}

init();
