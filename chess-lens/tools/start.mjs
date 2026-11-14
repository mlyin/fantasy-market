#!/usr/bin/env node
// Runs Chess Lens on this computer for phones on the same Wi-Fi, and shows a QR code to open it.
//
//   npm start               http, works straight away; on the phone use "Choose photo"
//   npm start -- --https    self-signed https, so the phone browser can also show a live camera
//                           (the phone warns about the certificate once; choose to continue)
//   npm start -- --port 9000
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { serve } from './serve.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const useHttps = args.includes('--https');
const portArg = args.indexOf('--port');
const port = portArg >= 0 ? Number(args[portArg + 1]) : 8787;
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error('--port needs a number between 1 and 65535');
  process.exit(1);
}

// 1. The real-board reader's files, so nothing has to come from the internet while you play.
const model = join(root, 'web/vendor/chesscam-model/chessq-chesscam-mnv4m-320-v1-fp16.tflite');
const runtime = join(root, 'web/vendor/litert/litert_wasm_internal.wasm');
if (!existsSync(model) || !existsSync(runtime)) {
  console.log('Fetching the real-board reader (about 70 MB, once)…');
  const fetched = spawnSync(process.execPath, [join(root, 'tools/vendor.mjs'), '--offline'], { stdio: 'inherit' });
  if (fetched.status !== 0) console.log('Could not fetch it now. The phone will download it the first time Real board is used.\n');
}

// 2. This computer's address on the local network.
const addresses = Object.values(networkInterfaces())
  .flat()
  .filter((a) => a && a.family === 'IPv4' && !a.internal)
  .map((a) => a.address);
const isPrivate = (ip) => /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip);
const address = addresses.find(isPrivate) || addresses[0];
if (!address) {
  console.error('This computer has no network address. Connect it to Wi-Fi or Ethernet and run this again.');
  process.exit(1);
}

// 3. Optional https with a throwaway certificate made for that address.
let tls;
if (useHttps) {
  const dir = join(root, '.cert');
  const keyFile = join(dir, 'key.pem');
  const certFile = join(dir, 'cert.pem');
  const madeFor = join(dir, 'address.txt');
  if (!existsSync(certFile) || !existsSync(madeFor) || readFileSync(madeFor, 'utf8') !== address) {
    mkdirSync(dir, { recursive: true });
    const base = ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '30', '-keyout', keyFile, '-out', certFile, '-subj', '/CN=Chess Lens (local)'];
    // Older OpenSSL builds lack -addext; the certificate is accepted by hand either way.
    let made = spawnSync('openssl', [...base, '-addext', `subjectAltName=IP:${address},DNS:localhost`], { stdio: 'ignore' });
    if (made.status !== 0) made = spawnSync('openssl', base, { stdio: 'ignore' });
    if (made.status !== 0) {
      console.error('Could not create a certificate (is openssl installed?). Run without --https instead.');
      process.exit(1);
    }
    writeFileSync(madeFor, address);
  }
  tls = { key: readFileSync(keyFile), cert: readFileSync(certFile) };
}

try {
  await serve({ port, host: '0.0.0.0', tls });
} catch (err) {
  console.error(err.code === 'EADDRINUSE' ? `Port ${port} is already in use. Try: npm start -- --port ${port + 1}` : `Could not start: ${err.message}`);
  process.exit(1);
}

const url = `${useHttps ? 'https' : 'http'}://${address}:${port}/`;
console.log(await QRCode.toString(url, { type: 'terminal', small: true }));
console.log(`Chess Lens is running at ${url}`);
console.log('Scan the code with your phone (same Wi-Fi as this computer). Keep this window open; Ctrl+C stops it.');
console.log(
  useHttps
    ? 'The phone will warn that the certificate is not trusted: choose "Show Details" then "visit this website".'
    : 'On the phone, use "Choose photo" then "Take Photo". For a live viewfinder instead, run: npm start -- --https',
);
if (addresses.length > 1) console.log(`Other addresses of this computer: ${addresses.filter((a) => a !== address).join(', ')}`);

// A big copy of the code on this computer's screen, easier to scan from across the desk.
const png = join(root, 'qr.png');
try {
  await QRCode.toFile(png, url, { width: 720, margin: 3 });
  if (process.platform === 'darwin') spawnSync('open', [png], { stdio: 'ignore' });
  else console.log(`QR code image: ${png}`);
} catch {
  // The terminal copy above is enough.
}
