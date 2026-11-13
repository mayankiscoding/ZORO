// Writes the app shell's file list and version into sw.js.
//
//   node web/tools/stamp-shell.mjs          rewrite the marked lines in sw.js
//   node web/tools/stamp-shell.mjs --check  exit 1 when sw.js is out of date
//
// The version is a hash of every shell file, so any change to the app gives the service worker
// a new cache name and the owner an "update ready" notice. Nothing outside the shell (tests,
// tools, the README) is listed, and nothing from the API ever can be.

import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const WEB_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SHELL_DIRS = ['css', 'js', 'icons'];
const SHELL_ROOT_FILES = ['index.html', 'manifest.webmanifest'];
const SHELL_EXTENSIONS = new Set(['.html', '.css', '.js', '.png', '.svg', '.webmanifest']);
const BLOCK = /\/\* shell:begin \*\/[\s\S]*?\/\* shell:end \*\//;

function walk(dir) {
  return readdirSync(dir)
    .sort()
    .flatMap((name) => {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) return walk(path);
      const dot = name.lastIndexOf('.');
      return dot > 0 && SHELL_EXTENSIONS.has(name.slice(dot)) ? [path] : [];
    });
}

/** Shell files, relative to web/, with forward slashes, sorted. */
export function shellFiles(root = WEB_ROOT) {
  const files = [...SHELL_ROOT_FILES.map((name) => join(root, name)), ...SHELL_DIRS.flatMap((dir) => walk(join(root, dir)))];
  return files.map((path) => relative(root, path).split(sep).join('/')).sort();
}

export function shellVersion(root = WEB_ROOT, files = shellFiles(root)) {
  const hash = createHash('sha256');
  for (const file of files) {
    hash.update(file);
    hash.update('\0');
    hash.update(readFileSync(join(root, file)));
    hash.update('\0');
  }
  return hash.digest('hex').slice(0, 16);
}

export function shellBlock(root = WEB_ROOT) {
  const files = shellFiles(root);
  const list = files.map((file) => `  '${file}',`).join('\n');
  return `/* shell:begin */\nconst SHELL_VERSION = '${shellVersion(root, files)}';\nconst SHELL_FILES = [\n${list}\n];\n/* shell:end */`;
}

/** @returns {{current: boolean, text: string}} the stamped text of sw.js */
export function stamped(root = WEB_ROOT) {
  const source = readFileSync(join(root, 'sw.js'), 'utf8');
  if (!BLOCK.test(source)) throw new Error('sw.js has no shell:begin / shell:end block');
  const text = source.replace(BLOCK, () => shellBlock(root));
  return { current: text === source, text };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result = stamped();
  if (process.argv.includes('--check')) {
    console.log(result.current ? 'sw.js is up to date' : 'sw.js is out of date: run node tools/stamp-shell.mjs');
    process.exit(result.current ? 0 : 1);
  }
  if (!result.current) writeFileSync(join(WEB_ROOT, 'sw.js'), result.text);
  console.log(`${result.current ? 'unchanged' : 'stamped'}: ${shellFiles().length} files, version ${shellVersion()}`);
}
