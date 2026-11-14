// Builds the third-party code the real-board reader needs.
//
//   node tools/vendor.mjs            Rebuild web/vendor/chesscam/{recorder,worker}.js (committed).
//   node tools/vendor.mjs --offline  Also put the LiteRT runtime and the model next to them, so the
//                                    app works with no network (not committed: about 70 MB, and the
//                                    model has its own licence). The iOS builds run this.
//
// Without --offline assets the app loads the runtime from jsDelivr and the model from Hugging Face
// the first time the real-board mode is used.
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'web/vendor');
const recorderDir = join(root, 'node_modules/@chesscam/recorder');
const litertDir = join(root, 'node_modules/@litertjs/core');
if (!existsSync(recorderDir) || !existsSync(litertDir)) throw new Error('run `npm install` in chess-lens first');
const version = (dir) => JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).version;

const banner = (name, licence, dir) => `/* ${name} ${version(dir)} (${licence}), bundled by chess-lens/tools/vendor.mjs. See LICENSES.md in this folder. */`;
const common = { bundle: true, format: 'esm', platform: 'browser', target: 'es2022', minify: false, legalComments: 'inline', logLevel: 'warning' };

mkdirSync(join(out, 'chesscam'), { recursive: true });
await build({
  ...common,
  entryPoints: [join(root, 'tools/realboard-entry.mjs')],
  outfile: join(out, 'chesscam/recorder.js'),
  banner: { js: banner('@chesscam/recorder', 'MIT', recorderDir) },
});
// The recorder starts its worker with new URL("./worker.js", import.meta.url), so the worker
// bundle has to sit next to recorder.js under exactly that name.
await build({
  ...common,
  entryPoints: [join(recorderDir, 'dist/vision/worker.js')],
  outfile: join(out, 'chesscam/worker.js'),
  banner: { js: `${banner('@chesscam/recorder', 'MIT', recorderDir)}\n${banner('@litertjs/core', 'Apache-2.0', litertDir)}` },
});
writeFileSync(
  join(out, 'chesscam/LICENSES.md'),
  `# Third-party code in this folder

recorder.js and worker.js are bundles of:

- @chesscam/recorder ${version(recorderDir)}, MIT. https://github.com/Pbatch/ChessCamRecorder

${readFileSync(join(recorderDir, 'LICENSE.md'), 'utf8').trim()}

- @litertjs/core ${version(litertDir)}, Apache License 2.0. https://github.com/google-ai-edge/LiteRT

The model these run, chessq-chesscam, is not in this repository. It is downloaded at runtime (or at
build time for the iOS app) from https://huggingface.co/PBatch23888/chessq-chesscam and is under the
PolyForm Noncommercial License 1.0.0: personal and other non-commercial use only.
`,
);
console.log('built web/vendor/chesscam/recorder.js and worker.js');

if (process.argv.includes('--offline')) {
  // Pinned exactly as the ChessCam app pins it (src/model.json in Pbatch/CameraChessWeb).
  const MODEL = {
    base: 'https://huggingface.co/PBatch23888/chessq-chesscam/resolve/0c3de0dd34a5e1a60d69e942045fb6dc0f82aeb4',
    file: 'chessq-chesscam-mnv4m-320-v1-fp16.tflite',
    sha256: '460c24aabf289a18b02069dfd957f940aae303862d7859409ad097a339a59013',
  };
  cpSync(join(litertDir, 'wasm'), join(out, 'litert'), { recursive: true });
  console.log('copied the LiteRT runtime to web/vendor/litert');

  const modelDir = join(out, 'chesscam-model');
  mkdirSync(modelDir, { recursive: true });
  const target = join(modelDir, MODEL.file);
  const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
  if (existsSync(target) && sha256(readFileSync(target)) === MODEL.sha256) {
    console.log('model already present');
  } else {
    // Connections to the file host drop now and then, so each file gets a few attempts.
    const get = async (name) => {
      let last;
      for (let attempt = 1; attempt <= 4; attempt++) {
        try {
          const response = await fetch(`${MODEL.base}/${name}`);
          if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
          return Buffer.from(await response.arrayBuffer());
        } catch (err) {
          last = err;
          if (attempt < 4) await new Promise((resolve) => setTimeout(resolve, attempt * 2000));
        }
      }
      throw new Error(`downloading ${name} failed after 4 attempts: ${last?.cause?.code || last?.message}`);
    };
    try {
      const bytes = await get(MODEL.file);
      if (sha256(bytes) !== MODEL.sha256) throw new Error(`${MODEL.file} does not match the pinned SHA-256`);
      // The licence has to travel with the weights, so the model is only kept once both are here.
      const notices = [];
      for (const name of ['LICENSE', 'NOTICE']) notices.push([name, await get(name)]);
      for (const [name, body] of notices) writeFileSync(join(modelDir, name), body);
      writeFileSync(target, bytes);
      console.log(`downloaded ${MODEL.file} (${(bytes.length / 1e6).toFixed(1)} MB) with its LICENSE and NOTICE`);
    } catch (err) {
      console.error(`Could not fetch the model: ${err.message}`);
      process.exit(1);
    }
  }
}
