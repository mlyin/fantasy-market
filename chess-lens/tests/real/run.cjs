// Runs the real-board reader on photos of a physical board with known positions, in a headless
// browser, and prints how it did. Needs the reader's files next to the app first:
//
//   npm run vendor:offline        (LiteRT runtime + model into web/vendor)
//   node tests/real/run.cjs       (CHROMIUM_PATH=/path/to/chrome to use a specific browser)
//
// It fails only when the reader cannot run at all; accuracy is reported, not asserted, until there
// is enough evidence to set a bar.
const { chromium } = require('playwright');
const { spawn } = require('node:child_process');
const { readFileSync, appendFileSync } = require('node:fs');
const { join } = require('node:path');

const root = join(__dirname, '../..');
const port = Number(process.env.PORT || 8791);
const labels = JSON.parse(readFileSync(join(__dirname, 'labels.json'), 'utf8'));

const cellsOf = (placement) => {
  const cells = [];
  for (const ch of placement.replace(/\//g, '')) {
    if (ch >= '1' && ch <= '8') for (let k = 0; k < Number(ch); k++) cells.push('');
    else cells.push(ch);
  }
  return cells;
};
const wrong = (a, b) => a.reduce((n, v, i) => n + (v === b[i] ? 0 : 1), 0);

(async () => {
  const server = spawn(process.execPath, [join(root, 'tools/serve.mjs')], { env: { ...process.env, PORT: String(port) }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise((resolve, reject) => {
    server.stdout.once('data', resolve);
    server.once('exit', (code) => reject(new Error(`server exited (${code})`)));
  });
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  let failed = false;
  const rows = [];
  try {
    const page = await browser.newPage();
    page.on('pageerror', (e) => console.error('page error:', e.message));
    await page.goto(`http://localhost:${port}/`);
    for (const label of labels) {
      const dataUrl = 'data:image/jpeg;base64,' + readFileSync(join(__dirname, label.file)).toString('base64');
      let result;
      try {
        result = await page.evaluate(async (src) => {
          const { scanRealBoard } = await import('/realboard.js');
          const img = new Image();
          img.src = src;
          await img.decode();
          const canvas = document.createElement('canvas');
          canvas.width = img.naturalWidth;
          canvas.height = img.naturalHeight;
          canvas.getContext('2d', { willReadFrequently: true }).drawImage(img, 0, 0);
          const r = await scanRealBoard(canvas);
          return { cells: r.cells, located: r.located, flipped: r.flipped, unsure: r.unsure.length, ms: r.ms, fen: r.fen };
        }, dataUrl);
      } catch (err) {
        failed = true;
        rows.push({ file: label.file, error: String(err.message || err).split('\n')[0] });
        continue;
      }
      const truth = cellsOf(label.placement);
      const asRead = wrong(result.cells, truth);
      const turned = wrong([...result.cells].reverse(), truth);
      rows.push({
        file: label.file,
        pieces: truth.filter(Boolean).length,
        located: result.located,
        wrong: Math.min(asRead, turned),
        orientation: asRead <= turned ? 'as photographed' : 'read from the other side',
        unsure: result.unsure,
        ms: result.ms,
        read: result.fen.split(' ')[0],
        expected: label.placement,
      });
    }
  } finally {
    await browser.close();
    server.kill();
  }

  const ok = rows.filter((r) => !r.error);
  const lines = [
    '| Photo | Pieces | Board found | Squares wrong | Orientation | Flagged unsure | Time |',
    '| --- | --- | --- | --- | --- | --- | --- |',
    ...rows.map((r) => (r.error ? `| ${r.file} | | | failed: ${r.error} | | | |` : `| ${r.file} | ${r.pieces} | ${r.located ? 'yes' : 'no'} | ${r.wrong} | ${r.orientation} | ${r.unsure} | ${r.ms} ms |`)),
  ];
  if (ok.length) {
    const squares = ok.length * 64;
    const bad = ok.reduce((n, r) => n + r.wrong, 0);
    lines.push('', `Squares right: ${(((squares - bad) / squares) * 100).toFixed(1)}% over ${ok.length} photos. Whole position right: ${ok.filter((r) => r.wrong === 0).length} of ${ok.length}.`);
  }
  for (const r of ok.filter((x) => x.wrong > 0)) lines.push('', `${r.file}: read \`${r.read}\`, expected \`${r.expected}\``);
  const report = lines.join('\n');
  console.log(report);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Real-board reader on real photos\n\n${report}\n`);
  process.exit(failed ? 1 : 0);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
