// Rasterises every lichess piece set to 128px RGBA PNGs for the synthetic data generator.
// Usage: node training/render_pieces.mjs <lila>/public/piece <outDir>
import { Resvg } from '@resvg/resvg-js';
import { readdirSync, readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const [src, out] = process.argv.slice(2);
if (!src || !out) throw new Error('usage: render_pieces.mjs <pieceDir> <outDir>');
const SIZE = 128;
const NAMES = ['wP', 'wN', 'wB', 'wR', 'wQ', 'wK', 'bP', 'bN', 'bB', 'bR', 'bQ', 'bK'];
let ok = 0;
const bad = [];
for (const set of readdirSync(src).sort()) {
  const dir = join(src, set);
  if (!statSync(dir).isDirectory()) continue;
  const rendered = [];
  for (const name of NAMES) {
    try {
      const svg = readFileSync(join(dir, `${name}.svg`));
      const png = new Resvg(svg, { fitTo: { mode: 'width', value: SIZE }, font: { loadSystemFonts: true } })
        .render()
        .asPng();
      rendered.push([name, png]);
    } catch (err) {
      bad.push(`${set}/${name}: ${err.message}`);
    }
  }
  if (rendered.length !== NAMES.length) continue;
  mkdirSync(join(out, set), { recursive: true });
  for (const [name, png] of rendered) writeFileSync(join(out, set, `${name}.png`), png);
  ok++;
}
console.log(`rendered ${ok} sets`);
if (bad.length) console.log('skipped:\n' + bad.join('\n'));
