// Draws the ZORO app icon and exports it: SVG for browsers, PNG for the Home Screen.
//
//   node web/tools/make-icons.mjs
//
// The icon is the orb at rest: the eye of a peacock feather (deep neel centre, a band of mor,
// one thread of genda, neel at the rim) on a deep neel ground. It is drawn here from numbers,
// not traced from anything: no third-party asset, no brand mark, no generated imagery.
// One model produces both forms, so the SVG and the PNGs cannot drift apart. No dependencies:
// the PNG encoder below uses only node:zlib.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, deflateSync } from 'node:zlib';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'icons');

// Everything is in units of the icon's side (0..1).
export const MODEL = Object.freeze({
  ground: [21, 22, 66], // deep neel
  groundEdge: [14, 15, 46],
  centre: [0.5, 0.5],
  eye: [0.478, 0.47], // the eye sits a little up and left, as in the idle orb
  radius: 0.285, // inside the maskable safe zone (a circle of radius 0.4)
  halo: { color: [91, 98, 224], inner: 0.2, outer: 0.47, alpha: 0.34 },
  // Radial stops from the eye outward, in units of the body radius.
  stops: [
    [0.0, [52, 62, 150]],
    [0.2, [105, 106, 228]],
    [0.44, [58, 140, 200]],
    [0.6, [25, 181, 176]],
    [0.675, [25, 181, 176]],
    [0.71, [214, 190, 92]],
    [0.745, [38, 160, 190]],
    [0.88, [79, 110, 218]],
    [1.0, [91, 98, 224]],
  ],
  cornerRadius: 0.225, // of the rounded square used for the plain ("any") icon
});

const lerp = (a, b, t) => a + (b - a) * t;
const mix = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
const clamp01 = (v) => Math.max(0, Math.min(1, v));

function bandColor(t) {
  const stops = MODEL.stops;
  if (t <= 0) return stops[0][1];
  for (let i = 1; i < stops.length; i += 1) {
    if (t <= stops[i][0]) {
      const [t0, c0] = stops[i - 1];
      const [t1, c1] = stops[i];
      return mix(c0, c1, (t - t0) / (t1 - t0 || 1));
    }
  }
  return stops[stops.length - 1][1];
}

/** Colour of one point (x, y in 0..1). Returns [r, g, b, a]. */
function sample(x, y, { rounded }) {
  if (rounded) {
    const r = MODEL.cornerRadius;
    const dx = Math.max(r - x, 0, x - (1 - r));
    const dy = Math.max(r - y, 0, y - (1 - r));
    if (dx * dx + dy * dy > r * r) return [0, 0, 0, 0];
  }
  const [cx, cy] = MODEL.centre;
  const dCentre = Math.hypot(x - cx, y - cy);
  let color = mix(MODEL.ground, MODEL.groundEdge, clamp01(dCentre / 0.72));
  const { halo } = MODEL;
  if (dCentre < halo.outer) {
    const strength = halo.alpha * clamp01((halo.outer - dCentre) / (halo.outer - halo.inner)) ** 1.6;
    color = mix(color, halo.color, strength);
  }
  if (dCentre <= MODEL.radius) {
    // The gradient runs from the eye to the rim: at each point, how far along that ray it is.
    const [ex, ey] = MODEL.eye;
    const vx = x - ex;
    const vy = y - ey;
    const len = Math.hypot(vx, vy);
    let t = 0;
    if (len > 1e-9) {
      const ux = vx / len;
      const uy = vy / len;
      const ox = ex - cx;
      const oy = ey - cy;
      const b = ox * ux + oy * uy;
      const rim = -b + Math.sqrt(Math.max(0, b * b - (ox * ox + oy * oy - MODEL.radius * MODEL.radius)));
      t = clamp01(len / rim);
    }
    let body = bandColor(t);
    // Light on the feather, up and to the left.
    const light = clamp01(1 - Math.hypot(x - (cx - 0.1), y - (cy - 0.115)) / 0.26) * 0.2;
    body = mix(body, [255, 255, 255], light);
    const edge = clamp01((MODEL.radius - dCentre) / 0.012); // a soft rim
    color = mix(color, body, edge);
  }
  return [color[0], color[1], color[2], 1];
}

/** RGBA pixels of the icon at `size`, 3x3 supersampled. */
export function renderPixels(size, { rounded = false } = {}) {
  const pixels = new Uint8Array(size * size * 4);
  const taps = [1 / 6, 3 / 6, 5 / 6];
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      for (const oy of taps) {
        for (const ox of taps) {
          const s = sample((px + ox) / size, (py + oy) / size, { rounded });
          r += s[0] * s[3];
          g += s[1] * s[3];
          b += s[2] * s[3];
          a += s[3];
        }
      }
      const at = (py * size + px) * 4;
      pixels[at] = a ? Math.round(r / a) : 0;
      pixels[at + 1] = a ? Math.round(g / a) : 0;
      pixels[at + 2] = a ? Math.round(b / a) : 0;
      pixels[at + 3] = Math.round((a / 9) * 255);
    }
  }
  return pixels;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'latin1');
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
  return Buffer.concat([head, data, tail]);
}

/** Encode RGBA pixels as a PNG (8-bit, colour type 6, no interlace). */
export function encodePng(pixels, size) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y += 1) {
    raw[y * (stride + 1)] = 0; // filter: none
    Buffer.from(pixels.buffer, y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const rgb = (c) => `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`;

/** The same drawing as SVG (512 units). */
export function renderSvg({ rounded = false } = {}) {
  const S = 512;
  const [cx, cy] = MODEL.centre.map((v) => v * S);
  const [ex, ey] = MODEL.eye.map((v) => v * S);
  const r = MODEL.radius * S;
  const stops = MODEL.stops.map(([at, color]) => `<stop offset="${at}" stop-color="${rgb(color)}"/>`).join('');
  const { halo } = MODEL;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${S} ${S}" role="img" aria-label="ZORO">
  <defs>
    <radialGradient id="ground" cx="50%" cy="50%" r="72%"><stop offset="0" stop-color="${rgb(MODEL.ground)}"/><stop offset="1" stop-color="${rgb(MODEL.groundEdge)}"/></radialGradient>
    <radialGradient id="halo" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${cy}" r="${halo.outer * S}"><stop offset="${(halo.inner / halo.outer).toFixed(3)}" stop-color="${rgb(halo.color)}" stop-opacity="${halo.alpha}"/><stop offset="0.75" stop-color="${rgb(halo.color)}" stop-opacity="${(halo.alpha * 0.22).toFixed(3)}"/><stop offset="1" stop-color="${rgb(halo.color)}" stop-opacity="0"/></radialGradient>
    <radialGradient id="eye" gradientUnits="userSpaceOnUse" cx="${cx}" cy="${cy}" r="${r}" fx="${ex}" fy="${ey}">${stops}</radialGradient>
    <radialGradient id="light" gradientUnits="userSpaceOnUse" cx="${cx - 0.1 * S}" cy="${cy - 0.115 * S}" r="${0.26 * S}"><stop offset="0" stop-color="#fff" stop-opacity="0.2"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <clipPath id="body"><circle cx="${cx}" cy="${cy}" r="${r}"/></clipPath>
  </defs>
  <rect width="${S}" height="${S}"${rounded ? ` rx="${MODEL.cornerRadius * S}"` : ''} fill="url(#ground)"/>
  <circle cx="${cx}" cy="${cy}" r="${halo.outer * S}" fill="url(#halo)"/>
  <circle cx="${cx}" cy="${cy}" r="${r}" fill="url(#eye)"/>
  <rect width="${S}" height="${S}" fill="url(#light)" clip-path="url(#body)"/>
</svg>
`;
}

export const OUTPUTS = Object.freeze([
  { file: 'icon.svg', kind: 'svg', rounded: true },
  { file: 'icon-maskable.svg', kind: 'svg', rounded: false },
  { file: 'icon-192.png', kind: 'png', size: 192, rounded: true },
  { file: 'icon-512.png', kind: 'png', size: 512, rounded: true },
  { file: 'icon-maskable-192.png', kind: 'png', size: 192, rounded: false },
  { file: 'icon-maskable-512.png', kind: 'png', size: 512, rounded: false },
  { file: 'apple-touch-icon.png', kind: 'png', size: 180, rounded: false }, // iOS masks it; it must be opaque
]);

export function build(output) {
  if (output.kind === 'svg') return Buffer.from(renderSvg(output), 'utf8');
  return encodePng(renderPixels(output.size, output), output.size);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(OUT, { recursive: true });
  for (const output of OUTPUTS) {
    const data = build(output);
    writeFileSync(join(OUT, output.file), data);
    console.log(`${output.file}  ${data.length} bytes`);
  }
}
