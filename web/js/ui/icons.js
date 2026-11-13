// Line icons drawn for ZORO on a 24-unit grid (1.8 stroke, round caps). They are original
// drawings: no SF Symbols, no third-party icon set, no brand marks.

import { svgIcon } from './dom.js';

const PATHS = {
  // tab bar
  orb: ['M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 0 0 0-17z', 'M12 8.2a3.8 3.8 0 1 0 0 7.6a3.8 3.8 0 0 0 0-7.6z'],
  spaces: ['M4.5 4.5h6v6h-6z', 'M13.5 4.5h6v6h-6z', 'M4.5 13.5h6v6h-6z', 'M13.5 13.5h6v6h-6z'],
  activity: ['M3 12.5h4l2.5-6.5l4 12l2.5-5.5H21'],
  you: ['M12 12a4 4 0 1 0 0-8a4 4 0 0 0 0 8z', 'M4.5 20.5c1-3.6 3.9-5.5 7.5-5.5s6.500 1.9 7.5 5.5'],
  // composer and voice
  waveform: ['M5 10v4', 'M8.5 6.5v11', 'M12 3.500v17', 'M15.5 7.500v9', 'M19 10v4'],
  send: ['M12 19.500V5', 'M6 10.500l6-6l6 6'],
  stop: ['M7.500 7.500h9v9h-9z'],
  keyboard: ['M3.500 6.500h17v11h-17z', 'M7 10.500h.01', 'M10.500 10.500h.01', 'M14 10.500h.01', 'M17.500 10.500h.01', 'M8 14h8'],
  speaker: ['M4.500 9.500v5h3.500l4.500 4v-13l-4.500 4z', 'M16 9a4 4 0 0 1 0 6', 'M18.500 6.500a7.500 7.500 0 0 1 0 11'],
  plus: ['M12 5v14', 'M5 12h14'],
  // privacy and security
  lock: ['M6.500 10.500h11v9h-11z', 'M8.500 10.500V8a3.500 3.500 0 0 1 7 0v2.500'],
  cloud: ['M7.500 18.500a4 4 0 0 1-.6-7.950a5.500 5.500 0 0 1 10.700 1.200a3.400 3.400 0 0 1-.6 6.750z'],
  shield: ['M12 3.500l7 2.500v5.500c0 4.300-2.900 7.400-7 9c-4.100-1.600-7-4.700-7-9V6z'],
  // navigation and rows
  chevron: ['M9.500 5.500l6 6.500l-6 6.500'],
  back: ['M14.500 5.500l-6 6.500l6 6.500'],
  close: ['M6 6l12 12', 'M18 6L6 18'],
  check: ['M5 12.500l4.500 4.500L19 7.500'],
  trash: ['M5 7h14', 'M9.500 7V4.500h5V7', 'M7 7l.8 12.500h8.400L17 7'],
  clock: ['M12 3.500a8.500 8.500 0 1 0 0 17a8.500 8.500 0 0 0 0-17z', 'M12 7.500V12l3 2'],
  link: ['M10 14a4 4 0 0 0 5.700 0l3-3a4 4 0 0 0-5.700-5.700l-1 1', 'M14 10a4 4 0 0 0-5.700 0l-3 3a4 4 0 0 0 5.700 5.700l1-1'],
  refresh: ['M19.500 12a7.500 7.500 0 1 1-2.200-5.300', 'M19.500 4.500v4h-4'],
  info: ['M12 3.500a8.500 8.500 0 1 0 0 17a8.500 8.500 0 0 0 0-17z', 'M12 11v5.500', 'M12 7.800h.01'],
  alert: ['M12 4l9 15.500H3z', 'M12 10v4.500', 'M12 17.200h.01'],
  // spaces and you
  basket: ['M4 9.500h16l-1.500 10h-13z', 'M8.500 9.500l3.500-6l3.500 6'],
  rupee: ['M7 5h10', 'M7 9h10', 'M7 5h3.500a4 4 0 0 1 0 8H7l7 6.500'],
  memory: ['M7 3.500h10v17l-5-3.500l-5 3.500z'],
  gear: ['M12 9a3 3 0 1 0 0 6a3 3 0 0 0 0-6z', 'M12 3v2.500', 'M12 18.500V21', 'M3 12h2.500', 'M18.500 12H21', 'M5.600 5.600l1.800 1.800', 'M16.600 16.600l1.800 1.800', 'M5.600 18.400l1.800-1.800', 'M16.600 7.400l1.800-1.800'],
  phone: ['M8 3.500h8v17H8z', 'M11 17.500h2'],
  laptop: ['M5.500 5.500h13v10h-13z', 'M3 18.500h18'],
  globe: ['M12 3.500a8.500 8.500 0 1 0 0 17a8.500 8.500 0 0 0 0-17z', 'M3.500 12h17', 'M12 3.500c2.500 2.500 2.500 14.500 0 17', 'M12 3.500c-2.500 2.500-2.500 14.500 0 17'],
  message: ['M4.500 5.500h15v11h-8l-4 3.500v-3.500h-3z'],
};

export const ICON_NAMES = Object.freeze(Object.keys(PATHS));

/** @param {keyof typeof PATHS} name @param {{size?: number}} [options] */
export function icon(name, options) {
  return svgIcon(PATHS[name] ?? PATHS.info, options);
}
