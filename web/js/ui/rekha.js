// The rekha waveform: sound drawn on the one line that carries the conversation. ZORO's levels
// stand on the line in genda (left half), the owner's hang from it in mor (right half).
// Silence draws no bar, so the line stays clean. The line itself is a CSS rule; this canvas
// only adds the bars and is hidden from assistive technology.

import { LevelRing } from '../voice/levels.js';
import { PALETTES, rgba } from './orb-params.js';

const BARS = 30; // per half
const SAMPLE_MS = 55;

/** Bar rectangles for one frame, in CSS pixels relative to the canvas. Pure, for tests.
 * @param {{width: number, height: number, zoro: number[], owner: number[]}} input
 * @returns {{x: number, y: number, w: number, h: number, voice: 'zoro' | 'owner'}[]} */
export function rekhaBars({ width, height, zoro, owner }) {
  const mid = height / 2;
  const half = width / 2;
  const reach = mid - 1;
  const bars = [];
  const layout = (values, offset, voice) => {
    const count = values.length;
    if (!count) return;
    const pitch = half / count;
    const w = Math.max(1.5, Math.min(4, pitch * 0.5));
    values.forEach((value, i) => {
      if (!(value > 0)) return; // silence: nothing is drawn
      const h = Math.max(2, Math.min(reach, value * reach));
      const x = offset + i * pitch + (pitch - w) / 2;
      bars.push({ x, y: voice === 'zoro' ? mid - h : mid, w, h, voice });
    });
  };
  layout(zoro, 0, 'zoro');
  layout(owner, half, 'owner');
  return bars;
}

export class RekhaWaveform {
  /** @param {HTMLCanvasElement} canvas
   * @param {{ownerLevel: () => number, zoroLevel: () => number, reduceMotion?: () => boolean}} options */
  constructor(canvas, { ownerLevel, zoroLevel, reduceMotion = () => false }) {
    this._canvas = canvas;
    this._ctx = canvas.getContext('2d');
    this._ownerLevel = ownerLevel;
    this._zoroLevel = zoroLevel;
    this._reduceMotion = reduceMotion;
    this._owner = new LevelRing(BARS);
    this._zoro = new LevelRing(BARS);
    this._active = false;
    this._frame = 0;
    this._lastSample = 0;
    this._tick = this._tick.bind(this);
    this._scheme = globalThis.matchMedia?.('(prefers-color-scheme: dark)') ?? null;
  }

  /** Start sampling (a voice is live) or let the bars run out and stop. */
  setActive(active) {
    this._active = active;
    if (active && !this._frame && !document.hidden) this._frame = requestAnimationFrame(this._tick);
  }

  _tick(now) {
    this._frame = 0;
    if (now - this._lastSample >= SAMPLE_MS) {
      this._lastSample = now;
      this._owner.push(this._active ? this._ownerLevel() : 0);
      this._zoro.push(this._active ? this._zoroLevel() : 0);
      this._draw();
    }
    const drained = this._owner.silent && this._zoro.silent;
    if ((this._active || !drained) && !document.hidden) this._frame = requestAnimationFrame(this._tick);
    else if (!this._active) this._clear();
  }

  _clear() {
    this._owner.clear();
    this._zoro.clear();
    this._ctx.clearRect(0, 0, this._canvas.width, this._canvas.height);
  }

  _draw() {
    const rect = this._canvas.getBoundingClientRect();
    if (!rect.width) return;
    const ratio = Math.min(globalThis.devicePixelRatio || 1, 2.5);
    const width = Math.round(rect.width * ratio);
    const height = Math.round(rect.height * ratio);
    if (this._canvas.width !== width || this._canvas.height !== height) {
      this._canvas.width = width;
      this._canvas.height = height;
    }
    const ctx = this._ctx;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, rect.width, rect.height);
    const palette = PALETTES[this._scheme?.matches ? 'dark' : 'light'];
    // Under Reduce Motion the history does not scroll: one bar per voice shows the level now.
    const still = this._reduceMotion();
    const zoro = still ? [Math.max(...this._zoro.values())] : this._zoro.values();
    const owner = still ? [Math.max(...this._owner.values())] : this._owner.values();
    for (const bar of rekhaBars({ width: rect.width, height: rect.height, zoro, owner })) {
      ctx.fillStyle = rgba(bar.voice === 'zoro' ? palette.genda : palette.mor, 1);
      ctx.beginPath();
      if (ctx.roundRect) ctx.roundRect(bar.x, bar.y, bar.w, bar.h, bar.w / 2);
      else ctx.rect(bar.x, bar.y, bar.w, bar.h);
      ctx.fill();
    }
  }

  destroy() {
    cancelAnimationFrame(this._frame);
    this._frame = 0;
  }
}
