// Starts the real ZORO backend for the end-to-end test: uvicorn from the backend virtualenv on a
// free local port, with a temporary SQLite database and temporary local state. Nothing is
// mocked. The server process gets a minimal environment (no provider keys), so it cannot reach
// any external service; strict private mode is its default.

import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..', '..', '..');
export const BACKEND_DIR = join(REPO_ROOT, 'backend');
export const BACKEND_PYTHON = join(BACKEND_DIR, '.venv', 'bin', 'python');

export function backendAvailable() {
  return existsSync(BACKEND_PYTHON);
}

/** A TCP port that was free a moment ago on 127.0.0.1. */
export async function freePort() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  server.close();
  await once(server, 'close');
  return port;
}

function serverEnv(workdir, port) {
  return {
    PATH: process.env.PATH ?? '/usr/bin:/bin',
    HOME: process.env.HOME ?? workdir,
    LANG: 'en_US.UTF-8',
    PYTHONUNBUFFERED: '1',
    PYTHONDONTWRITEBYTECODE: '1',
    // `development` keeps the generated signing keys in ZORO_LOCAL_DIR, so the CLI process that
    // makes the pairing code and the server process share them (in `test` they are per process).
    ZORO_ENV: 'development',
    ZORO_DATABASE_URL: `sqlite+aiosqlite:///${join(workdir, 'zoro.db')}`,
    ZORO_LOCAL_DIR: join(workdir, 'local'),
    ZORO_OBJECT_DIR: join(workdir, 'objects'),
    ZORO_PUBLIC_BASE_URL: `http://127.0.0.1:${port}`,
    ZORO_LOG_LEVEL: 'WARNING',
  };
}

/** Run a backend Python module to completion and return its stdout.
 * @param {string[]} args @param {Record<string, string>} env */
async function runPython(args, env) {
  const child = spawn(BACKEND_PYTHON, args, { cwd: BACKEND_DIR, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => (stdout += chunk));
  child.stderr.setEncoding('utf8').on('data', (chunk) => (stderr += chunk));
  const [code] = await once(child, 'exit');
  if (code !== 0) throw new Error(`python ${args.join(' ')} exited ${code}: ${stderr.slice(-2000)}`);
  return stdout;
}

/** Start the backend and wait until `/healthz` answers.
 * @returns {Promise<{baseUrl: string, port: number, workdir: string, env: Record<string, string>,
 *   pairingCode: () => Promise<string>, logs: () => string, stop: () => Promise<void>}>} */
export async function startBackend({ startupTimeoutMs = 90_000 } = {}) {
  if (!backendAvailable()) throw new Error(`backend virtualenv not found at ${BACKEND_PYTHON}`);
  const workdir = await mkdtemp(join(tmpdir(), 'zoro-web-e2e-'));
  const port = await freePort();
  const env = serverEnv(workdir, port);
  const baseUrl = `http://127.0.0.1:${port}`;

  const child = spawn(
    BACKEND_PYTHON,
    ['-m', 'uvicorn', 'app.main:create_app', '--factory', '--host', '127.0.0.1', '--port', String(port), '--log-level', 'warning'],
    { cwd: BACKEND_DIR, env, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let output = '';
  const keep = (chunk) => {
    output = (output + chunk).slice(-20_000);
  };
  child.stdout.setEncoding('utf8').on('data', keep);
  child.stderr.setEncoding('utf8').on('data', keep);
  let exited = null;
  child.once('exit', (code, signal) => {
    exited = { code, signal };
  });

  const stop = async () => {
    if (!exited) {
      child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 10_000);
      await once(child, 'exit').catch(() => {});
      clearTimeout(timer);
    }
    await rm(workdir, { recursive: true, force: true });
  };

  const deadline = Date.now() + startupTimeoutMs;
  for (;;) {
    if (exited) {
      await stop();
      throw new Error(`backend exited during startup (${JSON.stringify(exited)}):\n${output}`);
    }
    try {
      const response = await fetch(`${baseUrl}/healthz`, { signal: AbortSignal.timeout(2000) });
      if (response.ok) break;
    } catch {
      /* not listening yet */
    }
    if (Date.now() > deadline) {
      await stop();
      throw new Error(`backend did not answer /healthz within ${startupTimeoutMs} ms:\n${output}`);
    }
    await new Promise((done) => setTimeout(done, 250));
  }

  return {
    baseUrl,
    port,
    workdir,
    env,
    /** One-time pairing code from the operator CLI (`python -m app.cli pairing-code`). */
    async pairingCode() {
      const printed = await runPython(['-m', 'app.cli', 'pairing-code'], env);
      const match = /Pairing code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})/.exec(printed);
      if (!match) throw new Error(`could not read a pairing code from the CLI output:\n${printed}`);
      return match[1];
    },
    logs: () => output,
    stop,
  };
}
