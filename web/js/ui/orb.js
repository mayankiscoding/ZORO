// The orb: the eye of a peacock feather, drawn on a canvas.
//
// Frame policy: animated only while it is on screen and the page is visible; a still state under
// Reduce Motion is drawn once. The soft body is painted small on an offscreen canvas and scaled
// up, which gives the blur for free and keeps a phone at 60 frames a second.

import {
  bodyRadius,
  bodyStops,
  haloColor,
  mix,
  needsAnimation,
  orbParameters,
  PALETTES,
  rgba,
  satelliteAngles,
  shakeOffset,
} from './orb-params.js';

const BODY_PIXELS = 176; // offscreen resolution of the soft body
const OUTLINE_POINTS = 56;
const NUMERIC = ['scale', 'breath', 'deform', 'drift', 'iridescence', 'warmth', 'alarm', 'moon', 'levelGain', 'haloGain', 'halo'];
const EASE_SECONDS = 0.16;

export class Orb {
  /** @param {HTMLCanvasElement} canvas
   * @param {{reduceMotion?: () => boolean, level?: () => number}} [options] */
  constructor(canvas, { reduceMotion = () => false, level = () => 0 } = {}) {
    this._canvas = canvas;
    this._ctx = canvas.getContext('2d');
    this._body = document.createElement('canvas');
    this._body.width = BODY_PIXELS;
    this._body.height = BODY_PIXELS;
    this._bodyCtx = this._body.getContext('2d');
    this._reduceMotion = reduceMotion;
    this._level = level;
    this._state = 'idle';
    this._stateSince = 0;
    this._satellites = 0;
    this._params = orbParameters('idle', reduceMotion());
    this._target = this._params;
    this._scheme = 'light';
    this._surface = [242, 242, 247];
    this._frame = 0;
    this._last = 0;
    this._clock = 0;
    this._visible = true;
    this._running = false;
    this._shownOnce = false;
    this._size = 0;
    this._tick = this._tick.bind(this);

    this._schemeQuery = globalThis.matchMedia?.('(prefers-color-scheme: dark)') ?? null;
    this._onScheme = () => {
      this._readScheme();
      this.draw();
    };
    this._schemeQuery?.addEventListener?.('change', this._onScheme);
    this._onVisibility = () => this._sync();
    document.addEventListener('visibilitychange', this._onVisibility);
    this._observer = 'IntersectionObserver' in globalThis
      ? new IntersectionObserver((entries) => {
          this._visible = entries.some((entry) => entry.isIntersecting);
          this._sync();
        })
      : null;
    this._observer?.observe(canvas);
    this._resizer = 'ResizeObserver' in globalThis ? new ResizeObserver(() => this.resize()) : null;
    this._resizer?.observe(canvas);
    this._readScheme();
    this.resize();
  }

  _readScheme() {
    this._scheme = this._schemeQuery?.matches ? 'dark' : 'light';
    const value = getComputedStyle(this._canvas).getPropertyValue('--orb-surface').trim();
    const match = /^#([0-9a-f]{6})$/i.exec(value);
    if (match) {
      const n = Number.parseInt(match[1], 16);
      this._surface = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
  }

  /** Match the backing store to the element's size and the screen's pixel density. */
  resize() {
    const rect = this._canvas.getBoundingClientRect();
    const size = Math.round(Math.min(rect.width, rect.height));
    if (!size) return;
    const ratio = Math.min(globalThis.devicePixelRatio || 1, 2.5);
    const pixels = Math.round(size * ratio);
    if (this._canvas.width !== pixels) {
      this._canvas.width = pixels;
      this._canvas.height = pixels;
    }
    this._size = pixels;
    this.draw();
  }

  /** @param {string} state one of the eight orb states @param {number} [satellites] */
  setState(state, satellites = 0) {
    const changed = state !== this._state;
    if (changed) {
      this._state = state;
      this._stateSince = this._clock;
    }
    this._satellites = Math.max(0, Math.min(6, satellites));
    this._target = orbParameters(state, this._reduceMotion());
    // The first state is shown as it is; later changes ease in. Under Reduce Motion nothing eases.
    if (this._reduceMotion() || !this._shownOnce) this._params = this._target;
    this._shownOnce = true;
    this._sync();
    if (!this._running) this.draw();
  }

  get state() {
    return this._state;
  }

  /** The Reduce Motion setting changed. */
  motionChanged() {
    this._target = orbParameters(this._state, this._reduceMotion());
    this._params = this._target;
    this._sync();
    this.draw();
  }

  _shouldRun() {
    return this._visible && !document.hidden && this._size > 0 && needsAnimation(this._state, this._reduceMotion());
  }

  _sync() {
    const run = this._shouldRun();
    if (run && !this._running) {
      this._running = true;
      this._last = 0;
      this._frame = requestAnimationFrame(this._tick);
    } else if (!run && this._running) {
      this._running = false;
      cancelAnimationFrame(this._frame);
    }
  }

  _tick(now) {
    if (!this._running) return;
    const dt = this._last ? Math.min(0.05, (now - this._last) / 1000) : 1 / 60;
    this._last = now;
    this._clock += dt;
    const k = 1 - Math.exp(-dt / EASE_SECONDS);
    const next = { ...this._target };
    for (const key of NUMERIC) next[key] = this._params[key] + (this._target[key] - this._params[key]) * k;
    this._params = next;
    this.draw();
    this._frame = requestAnimationFrame(this._tick);
  }

  /** Paint one frame. */
  draw() {
    const size = this._size;
    if (!size) return;
    const ctx = this._ctx;
    const params = this._params;
    const scheme = this._scheme;
    const palette = PALETTES[scheme];
    const still = this._reduceMotion();
    const t = still ? 0 : this._clock;
    const level = Math.max(0, Math.min(1, this._level() || 0));
    const centre = size / 2;
    const base = (size / 2) * 0.56 * params.scale;
    const shake = params.shake ? shakeOffset(this._clock - this._stateSince, size * 0.035) : 0;
    const cx = centre + shake;
    const cy = centre;

    ctx.clearRect(0, 0, size, size);

    // Halo: the only thing that answers sound under Reduce Motion.
    const haloAlpha = Math.min(0.85, params.halo + params.haloGain * level);
    const halo = ctx.createRadialGradient(cx, cy, base * 0.6, cx, cy, base * 1.75);
    const glow = haloColor(params, scheme);
    halo.addColorStop(0, rgba(glow, haloAlpha));
    halo.addColorStop(0.55, rgba(glow, haloAlpha * 0.35));
    halo.addColorStop(1, rgba(glow, 0));
    ctx.fillStyle = halo;
    ctx.fillRect(0, 0, size, size);

    if (params.ripples) this._ripples(ctx, cx, cy, base, t, level, palette, still);
    this._paintBody(params, scheme, t, level);
    const span = base * 2.6;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(this._body, cx - span / 2, cy - span / 2, span, span);

    if (params.ring === 'sealed') this._sealedRing(ctx, cx, cy, base, palette, size);
    if (params.arc === 'turning') this._turningArc(ctx, cx, cy, base, t, palette, size);
    if (params.arc === 'sweep') this._sweepRing(ctx, cx, cy, base, t, palette, size, still);
    if (params.satellites !== 'none' && this._satellites > 0) {
      this._drawSatellites(ctx, cx, cy, base, t, palette, size, params.satellites);
    }
  }

  /** The body on the small canvas: a softly bent circle filled with the eye's bands. */
  _paintBody(params, scheme, t, level) {
    const ctx = this._bodyCtx;
    const n = BODY_PIXELS;
    const c = n / 2;
    const r = n / 2.6; // matches the 2.6 span used when it is scaled up
    ctx.clearRect(0, 0, n, n);
    const eyeX = c + r * 0.15 * Math.sin(t * 0.5 * params.drift + 0.6);
    const eyeY = c + r * 0.11 * Math.cos(t * 0.37 * params.drift);
    const gradient = ctx.createRadialGradient(eyeX, eyeY, 0, c, c, r * 1.12);
    const stops = bodyStops(params, scheme);
    for (const stop of stops) gradient.addColorStop(stop.at, rgba(stop.color, 1));
    ctx.fillStyle = gradient;
    // A feathered rim in the rim's own colour: scaled up, the edge reads as soft, not stepped.
    ctx.shadowColor = rgba(stops[stops.length - 1].color, 0.9);
    ctx.shadowBlur = n * 0.035;
    ctx.beginPath();
    for (let i = 0; i <= OUTLINE_POINTS; i += 1) {
      const angle = (i / OUTLINE_POINTS) * Math.PI * 2;
      const radius = bodyRadius(r, angle, t, params, level);
      const x = c + Math.cos(angle) * radius;
      const y = c + Math.sin(angle) * radius;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fill();
    ctx.shadowBlur = 0;
    ctx.shadowColor = 'transparent';
    // A soft highlight up and to the left, as light on a feather.
    const light = ctx.createRadialGradient(c - r * 0.35, c - r * 0.4, 0, c - r * 0.35, c - r * 0.4, r * 0.9);
    light.addColorStop(0, 'rgba(255,255,255,0.20)');
    light.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.globalCompositeOperation = 'source-atop';
    ctx.fillStyle = light;
    ctx.fillRect(0, 0, n, n);
    ctx.globalCompositeOperation = 'source-over';
  }

  _ripples(ctx, cx, cy, base, t, level, palette, still) {
    ctx.lineWidth = Math.max(1, this._size / 220);
    for (let i = 0; i < 3; i += 1) {
      const phase = still ? (i + 1) / 4 : (t * 0.28 + i / 3) % 1;
      const radius = base * (1.12 + phase * 0.62 + level * 0.06);
      ctx.strokeStyle = rgba(palette.mor, (1 - phase) * (0.35 + 0.4 * level));
      ctx.beginPath();
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  _sealedRing(ctx, cx, cy, base, palette, size) {
    const outer = base * 1.24;
    ctx.strokeStyle = rgba(palette.moon, 1);
    ctx.lineWidth = Math.max(1.5, size / 110);
    ctx.beginPath();
    ctx.arc(cx, cy, outer, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = rgba(palette.moon, 0.6);
    ctx.lineWidth = Math.max(1, size / 260);
    ctx.beginPath();
    ctx.arc(cx, cy, base * 1.13, 0, Math.PI * 2);
    ctx.stroke();
    // The clasp at 12 o'clock: the ring is sealed.
    ctx.fillStyle = rgba(palette.moon, 1);
    ctx.beginPath();
    ctx.arc(cx, cy - outer, Math.max(2.5, size / 70), 0, Math.PI * 2);
    ctx.fill();
  }

  _turningArc(ctx, cx, cy, base, t, palette, size) {
    const radius = base * 1.2;
    const start = t * 2.6;
    const sweep = Math.PI * 0.62;
    const steps = 14;
    ctx.lineWidth = Math.max(2, size / 85);
    ctx.lineCap = 'round';
    for (let i = 0; i < steps; i += 1) {
      const from = start + (sweep * i) / steps;
      const to = start + (sweep * (i + 1)) / steps + 0.01;
      ctx.strokeStyle = rgba(mix(palette.mor, palette.genda, i / (steps - 1)), 0.35 + 0.65 * (i / (steps - 1)));
      ctx.beginPath();
      ctx.arc(cx, cy, radius, from, to);
      ctx.stroke();
    }
    ctx.lineCap = 'butt';
  }

  _sweepRing(ctx, cx, cy, base, t, palette, size, still) {
    const radius = base * 1.2;
    ctx.lineWidth = Math.max(1, size / 240);
    ctx.strokeStyle = rgba(palette.mor, 0.28);
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.stroke();
    const phase = still ? 0.3 : (t / 1.8) % 1;
    ctx.lineWidth = Math.max(2, size / 95);
    ctx.lineCap = 'round';
    ctx.strokeStyle = rgba(palette.mor, phase > 0.85 ? (1 - phase) / 0.15 : 1);
    ctx.beginPath();
    ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(1, phase / 0.85));
    ctx.stroke();
    ctx.lineCap = 'butt';
  }

  _drawSatellites(ctx, cx, cy, base, t, palette, size, mode) {
    const docked = mode === 'docked';
    const orbit = docked ? base * 1.02 : base * 1.62;
    const radius = Math.max(4, size / 34);
    const color = docked ? palette.genda : palette.mor;
    for (const angle of satelliteAngles(this._satellites, mode, t)) {
      const x = cx + Math.cos(angle) * orbit;
      const y = cy + Math.sin(angle) * orbit;
      if (!docked) {
        ctx.setLineDash([Math.max(1.5, size / 160), Math.max(3, size / 80)]);
        ctx.strokeStyle = rgba(palette.mor, 0.5);
        ctx.lineWidth = Math.max(1, size / 260);
        ctx.beginPath();
        ctx.moveTo(cx + Math.cos(angle) * base * 1.06, cy + Math.sin(angle) * base * 1.06);
        ctx.lineTo(x - Math.cos(angle) * radius, y - Math.sin(angle) * radius);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      ctx.fillStyle = rgba(this._surface, 1);
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = rgba(color, 1);
      ctx.lineWidth = Math.max(1.5, size / 130);
      ctx.stroke();
      ctx.fillStyle = rgba(color, 1);
      ctx.beginPath();
      ctx.arc(x, y, radius * 0.32, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  /** Stop drawing and let go of observers (the screen is gone). */
  destroy() {
    this._running = false;
    cancelAnimationFrame(this._frame);
    this._schemeQuery?.removeEventListener?.('change', this._onScheme);
    document.removeEventListener('visibilitychange', this._onVisibility);
    this._observer?.disconnect();
    this._resizer?.disconnect();
  }
}
