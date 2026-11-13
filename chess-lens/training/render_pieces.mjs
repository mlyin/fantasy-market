// Rasterises SVG piece sets to 128px RGBA PNGs for the synthetic data generator.
// Usage: node training/render_pieces.mjs <pieceDir> <outDir> [prefix]
//   lichess:  <lila>/public/piece            (files named wK.svg)
//   pychess:  <pychess>/pieces  with prefix  (files named wk.svg); sets already rendered are skipped
import { Resvg } from '@resvg/resvg-js';
import { readdirSync, readFileSync, writeFileSync, mkdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [src, out, prefix = ''] = process.argv.slice(2);
if (!src || !out) throw new Error('usage: render_pieces.mjs <pieceDir> <outDir>');
const SIZE = 128;
const NAMES = ['wP', 'wN', 'wB', 'wR', 'wQ', 'wK', 'bP', 'bN', 'bB', 'bR', 'bQ', 'bK'];
let ok = 0;
const bad = [];
for (const set of readdirSync(src).sort()) {
  const dir = join(src, set);
  if (!statSync(dir).isDirectory()) continue;
  if (prefix && existsSync(join(out, set))) continue; // same set already rendered from another source
  const rendered = [];
  for (const name of NAMES) {
    try {
      const file = existsSync(join(dir, `${name}.svg`)) ? `${name}.svg` : `${name.toLowerCase()}.svg`;
      const svg = readFileSync(join(dir, file));
      const png = new Resvg(svg, { fitTo: { mode: 'width', value: SIZE }, font: { loadSystemFonts: true } })
        .render()
        .asPng();
      rendered.push([name, png]);
    } catch (err) {
      bad.push(`${set}/${name}: ${err.message}`);
    }
  }
  if (rendered.length !== NAMES.length) continue;
  mkdirSync(join(out, prefix + set), { recursive: true });
  for (const [name, png] of rendered) writeFileSync(join(out, prefix + set, `${name}.png`), png);
  ok++;
}
console.log(`rendered ${ok} sets`);
if (bad.length) console.log('skipped:\n' + bad.join('\n'));
