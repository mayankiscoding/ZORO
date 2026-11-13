// Serves the web app at /app/ and passes everything else to the ZORO backend, so the app and the
// API share one origin exactly as they will when the backend serves web/ itself.
//
//   node web/tools/serve.mjs --backend http://127.0.0.1:8000 --port 8765
//
// This is for development and for using the web app before the backend mounts it. It listens
// on 127.0.0.1 only and speaks plain HTTP: put `tailscale serve` (HTTPS on your tailnet) in
// front of it for an iPhone. No dependencies; streaming replies and the WebSocket device
// channel are passed through.

import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const WEB_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const MOUNT = '/app/';

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
};
// Only the app itself is served: no tests, tools, package metadata or dot files.
const SERVED_DIRS = new Set(['css', 'js', 'icons']);
const SERVED_ROOT_FILES = new Set(['index.html', 'manifest.webmanifest', 'sw.js']);

/** The headers the backend should send for web/ too. */
export const SECURITY_HEADERS = Object.freeze({
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'microphone=(self), camera=(), geolocation=(), payment=(), usb=()',
});

/** Map a request path under /app/ to a file in web/, or null when it must not be served. */
export function resolveAsset(pathname, root = WEB_ROOT) {
  if (!pathname.startsWith(MOUNT)) return null;
  let relative;
  try {
    relative = decodeURIComponent(pathname.slice(MOUNT.length));
  } catch {
    return null;
  }
  if (relative === '') relative = 'index.html';
  if (relative.includes('\0') || relative.includes('\\')) return null;
  const parts = normalize(relative).split(sep);
  if (parts.some((part) => part === '..' || part.startsWith('.'))) return null;
  const allowed = parts.length === 1 ? SERVED_ROOT_FILES.has(parts[0]) : SERVED_DIRS.has(parts[0]);
  if (!allowed) return null;
  const file = join(root, ...parts);
  if (!file.startsWith(root + sep) || !TYPES[extname(file)]) return null;
  if (!existsSync(file) || !statSync(file).isFile()) return null;
  return file;
}

function serveAsset(file, req, res) {
  const headers = {
    ...SECURITY_HEADERS,
    'Content-Type': TYPES[extname(file)],
    'Content-Length': statSync(file).size,
    // The service worker does the caching, with versions; the HTTP cache must always re-check.
    'Cache-Control': 'no-cache',
  };
  if (file.endsWith(`${sep}sw.js`)) headers['Service-Worker-Allowed'] = MOUNT;
  res.writeHead(200, headers);
  if (req.method === 'HEAD') res.end();
  else createReadStream(file).pipe(res);
}

function proxyHttp(backend, req, res) {
  const upstream = httpRequest(
    { host: backend.hostname, port: backend.port, method: req.method, path: req.url, headers: { ...req.headers, host: backend.host } },
    (answer) => {
      res.writeHead(answer.statusCode ?? 502, answer.headers);
      answer.pipe(res); // unbuffered: server-sent events arrive as they are written
    },
  );
  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ code: 'unavailable', message: 'The ZORO backend is not answering.', retryable: true }));
  });
  req.on('aborted', () => upstream.destroy());
  req.pipe(upstream);
}

function proxyUpgrade(backend, req, socket, head) {
  const upstream = connect(Number(backend.port), backend.hostname, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      lines.push(`${name}: ${name.toLowerCase() === 'host' ? backend.host : req.rawHeaders[i + 1]}`);
    }
    upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  const close = () => {
    upstream.destroy();
    socket.destroy();
  };
  upstream.on('error', close);
  socket.on('error', close);
}

/** @param {{backend: string, port?: number, host?: string}} options */
export function createWebServer({ backend, port = 8765, host = '127.0.0.1' }) {
  const target = new URL(backend);
  const server = createServer((req, res) => {
    const { pathname } = new URL(req.url, 'http://local');
    if (pathname === '/' || pathname === '/app') {
      res.writeHead(308, { Location: MOUNT });
      res.end();
      return;
    }
    if (pathname.startsWith(MOUNT)) {
      const file = req.method === 'GET' || req.method === 'HEAD' ? resolveAsset(pathname) : null;
      if (file) serveAsset(file, req, res);
      else {
        res.writeHead(404, { ...SECURITY_HEADERS, 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 'not_found', message: 'Not part of the web app.', retryable: false }));
      }
      return;
    }
    proxyHttp(target, req, res);
  });
  server.on('upgrade', (req, socket, head) => proxyUpgrade(target, req, socket, head));
  return new Promise((done, fail) => {
    server.once('error', fail);
    server.listen(port, host, () => done({ server, url: `http://${host}:${server.address().port}${MOUNT}`, port: server.address().port }));
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const arg = (name, fallback) => {
    const at = process.argv.indexOf(`--${name}`);
    return at > 0 && process.argv[at + 1] ? process.argv[at + 1] : fallback;
  };
  const backend = arg('backend', 'http://127.0.0.1:8000');
  const { url } = await createWebServer({ backend, port: Number(arg('port', '8765')) });
  console.log(`ZORO web app: ${url}`);
  console.log(`API passed through to: ${backend}`);
  console.log('For an iPhone, give it HTTPS on your tailnet: tailscale serve --bg <port>');
}
