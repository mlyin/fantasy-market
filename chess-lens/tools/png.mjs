// Decode a PNG file into { data: Uint8Array RGBA, width, height } (Node only; used by tests and training).
import { readFileSync } from 'node:fs';
import { PNG } from 'pngjs';

export function readPng(path) {
  const png = PNG.sync.read(readFileSync(path));
  return { data: png.data, width: png.width, height: png.height };
}
