// The orb's numbers and geometry: pure functions, no canvas. They follow the table in
// docs/design/design-system.md (section 3) so the web orb matches the native one state by state.

import { agentName, joinNames } from '../core/format.js';

export const ORB_STATES = Object.freeze(['idle', 'listening', 'processing', 'delegating', 'tool', 'speaking', 'error', 'private']);
export const MAX_SATELLITES = 6;

/** @typedef {{scale: number, breath: number, breathPeriod: number, deform: number, drift: number,
 *   iridescence: number, warmth: number, alarm: number, moon: number, levelGain: number,
 *   haloGain: number, halo: number, ripples: boolean, arc: 'none' | 'turning' | 'sweep',
 *   satellites: 'none' | 'orbiting' | 'docked', ring: 'none' | 'sealed', shake: boolean}} OrbParameters */

const BASE = Object.freeze({
  scale: 0.78,
  breath: 0.025,
  breathPeriod: 4.2,
  deform: 0.035,
  drift: 1,
  iridescence: 0.6,
  warmth: 0,
  alarm: 0,
  moon: 0,
  levelGain: 0,
  haloGain: 0.25,
  halo: 0.3,
  ripples: false,
  arc: 'none',
  satellites: 'none',
  ring: 'none',
  shake: false,
});

const PER_STATE = Object.freeze({
  idle: {},
  listening: { scale: 0.9, deform: 0.03, levelGain: 0.14, haloGain: 0.5, halo: 0.42, iridescence: 0.85, ripples: true, breath: 0.012 },
  processing: { scale: 0.76, iridescence: 1, drift: 2.6, deform: 0.05, arc: 'turning' },
  delegating: { scale: 0.68, iridescence: 0.9, drift: 1.6, satellites: 'orbiting' },
  tool: { scale: 0.7, iridescence: 0.9, drift: 1.2, satellites: 'docked', arc: 'sweep' },
  speaking: { scale: 0.84, warmth: 0.7, levelGain: 0.1, haloGain: 0.45, halo: 0.4, iridescence: 0.75, deform: 0.045 },
  error: { scale: 0.74, alarm: 0.75, iridescence: 0, breath: 0, deform: 0.01, drift: 0.2, shake: true, halo: 0.22 },
  private: { scale: 0.74, moon: 1, iridescence: 0, drift: 0.5, deform: 0.012, breath: 0.015, ring: 'sealed', halo: 0.24 },
});

/** Parameters for a state. Under Reduce Motion the orb is one still frame per state: no
 * deformation, breath, drift, ripple travel or shake; it answers sound with halo opacity only,
 * and keeps its palette, ring, arc and satellites so the state is still readable.
 * @param {string} state @param {boolean} [reduceMotion] @returns {OrbParameters} */
export function orbParameters(state, reduceMotion = false) {
  const params = { ...BASE, ...(PER_STATE[state] ?? PER_STATE.idle) };
  if (reduceMotion) {
    params.breath = 0;
    params.deform = 0;
    params.drift = 0;
    params.levelGain = 0;
    params.shake = false;
  }
  return params;
}

/** Whether a state needs continuous frames. A still state is drawn once and left alone. */
export function needsAnimation(state, reduceMotion) {
  if (!reduceMotion) return true;
  return state === 'listening' || state === 'speaking'; // halo opacity follows the sound
}

export const PALETTES = Object.freeze({
  light: Object.freeze({ neel: [42, 47, 143], mor: [11, 127, 134], genda: [217, 138, 0], lac: [181, 48, 42], moon: [110, 122, 138], deep: [24, 27, 96], lift: [112, 104, 196] }),
  dark: Object.freeze({ neel: [91, 98, 224], mor: [25, 181, 176], genda: [255, 179, 33], lac: [255, 107, 94], moon: [169, 180, 194], deep: [52, 62, 150], lift: [132, 122, 236] }),
});

/** @param {number[]} a @param {number[]} b @param {number} t 0..1 */
export function mix(a, b, t) {
  const k = Math.max(0, Math.min(1, t));
  return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k];
}

export function rgba(color, alpha = 1) {
  return `rgba(${Math.round(color[0])},${Math.round(color[1])},${Math.round(color[2])},${Math.max(0, Math.min(1, alpha)).toFixed(3)})`;
}

/** The peacock eye as radial stops from the eye's centre to the rim: a deep neel centre, a band
 * of mor, one thin thread of genda, neel again at the rim. Warmth brings marigold to the eye;
 * alarm replaces the stops with lac; moonstone removes the iridescence altogether.
 * @param {Pick<OrbParameters, 'iridescence' | 'warmth' | 'alarm' | 'moon'>} params
 * @param {'light' | 'dark'} scheme
 * @returns {{at: number, color: number[]}[]} */
export function bodyStops(params, scheme = 'light') {
  const p = PALETTES[scheme] ?? PALETTES.light;
  const irid = params.iridescence;
  let stops = [
    { at: 0, color: mix(p.deep, p.genda, params.warmth) },
    { at: 0.2, color: mix(mix(p.neel, p.lift, 0.35), p.genda, params.warmth * 0.55) },
    { at: 0.44, color: mix(p.neel, p.mor, 0.25 + 0.5 * irid) },
    { at: 0.6, color: mix(p.neel, p.mor, 0.35 + 0.65 * irid) },
    { at: 0.675, color: mix(p.neel, p.mor, 0.35 + 0.65 * irid) },
    { at: 0.71, color: mix(mix(p.neel, p.mor, 0.5), p.genda, 0.2 + 0.7 * irid) },
    { at: 0.745, color: mix(p.neel, p.mor, 0.3 + 0.5 * irid) },
    { at: 0.88, color: mix(p.neel, p.mor, 0.18 * irid) },
    { at: 1, color: p.neel },
  ];
  if (params.alarm > 0) {
    const shades = [0.78, 1, 0.92, 0.86, 0.86, 1.06, 0.9, 0.84, 0.8];
    stops = stops.map((stop, i) => ({ at: stop.at, color: mix(stop.color, p.lac.map((c) => Math.min(255, c * shades[i])), params.alarm) }));
  }
  if (params.moon > 0) {
    const shades = [0.8, 0.9, 0.98, 1.02, 1.02, 1.04, 1.02, 1, 0.97];
    stops = stops.map((stop, i) => ({ at: stop.at, color: mix(stop.color, p.moon.map((c) => Math.min(255, c * shades[i])), params.moon) }));
  }
  return stops;
}

/** Colour of the soft glow around the body. */
export function haloColor(params, scheme = 'light') {
  const p = PALETTES[scheme] ?? PALETTES.light;
  let color = mix(p.neel, p.mor, 0.25 * params.iridescence);
  color = mix(color, p.genda, params.warmth * 0.6);
  color = mix(color, p.lac, params.alarm);
  return mix(color, p.moon, params.moon);
}

/** Angles (radians, 0 = 3 o'clock, clockwise) of `count` satellites. Orbiting ones turn with
 * time; docked ones sit still on the rim starting at 12 o'clock.
 * @param {number} count @param {'orbiting' | 'docked'} mode @param {number} seconds */
export function satelliteAngles(count, mode, seconds = 0) {
  const n = Math.max(0, Math.min(MAX_SATELLITES, Math.floor(count)));
  const start = -Math.PI / 2 + (mode === 'orbiting' ? seconds * 0.55 : 0);
  return Array.from({ length: n }, (_unused, i) => start + (i * 2 * Math.PI) / Math.max(n, 1));
}

/** Radius of the body outline at an angle: a circle bent by two slow waves and, while a voice
 * is heard, by a faster ripple that grows with the level. Always within ±25 % of the base.
 * @param {number} base @param {number} angle @param {number} seconds
 * @param {Pick<OrbParameters, 'deform' | 'levelGain' | 'breath' | 'breathPeriod'>} params @param {number} level 0..1 */
export function bodyRadius(base, angle, seconds, params, level = 0) {
  const breath = params.breath * Math.sin((seconds * 2 * Math.PI) / params.breathPeriod);
  const slow = params.deform * (0.62 * Math.sin(2 * angle + seconds * 0.7) + 0.38 * Math.sin(3 * angle - seconds * 0.45 + 1.3));
  const voice = params.levelGain * level * (0.55 + 0.45 * Math.sin(5 * angle + seconds * 6));
  return base * Math.max(0.75, Math.min(1.25, 1 + breath + slow + voice));
}

/** One damped shake for the error state: 0.45 s, then exactly still.
 * @param {number} sinceStart seconds since the state was entered @param {number} amplitude */
export function shakeOffset(sinceStart, amplitude) {
  if (sinceStart < 0 || sinceStart >= 0.45) return 0;
  return amplitude * Math.exp(-sinceStart / 0.13) * Math.sin(sinceStart * 42);
}

/** What VoiceOver reads after the label "ZORO". Names the working agents.
 * @param {(key: string, params?: any) => string} t
 * @param {{state: string, agents?: string[], canListen?: boolean, waiting?: boolean}} facts */
export function orbValue(t, { state, agents = [], canListen = true, waiting = false }) {
  const names = joinNames(agents.map(agentName), t.lang);
  switch (state) {
    case 'listening':
      return t('orb.listening');
    case 'processing':
      return t('orb.processing');
    case 'delegating':
      if (waiting) return t('orb.waiting');
      return names ? t('orb.delegating', { agents: names }) : t('orb.delegating_none');
    case 'tool':
      if (waiting) return t('orb.waiting');
      return names ? t('orb.tool', { agents: names }) : t('orb.tool_none');
    case 'speaking':
      return t('orb.speaking');
    case 'error':
      return t('orb.error');
    case 'private':
      return t(canListen ? 'orb.private_talk' : 'orb.private_type');
    default:
      return t(canListen ? 'orb.idle' : 'orb.idle_type');
  }
}
