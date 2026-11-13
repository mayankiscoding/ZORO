// Sessions: challenge -> token, re-authentication on 401, and the cases that must not loop.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ApiError, ZoroClient } from '../js/core/api.js';
import { DeviceIdentity } from '../js/core/identity.js';
import { MemoryStore } from '../js/core/store.js';

function json(status, body, headers = {}) {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

function sse(events) {
  const text = events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
  return new Response(text, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

/** A scripted server: counts calls, issues tokens, and can be told which tokens are dead. */
function fakeServer({ ttl = 900 } = {}) {
  const state = { calls: [], tokens: 0, dead: new Set(), nonces: 0, handlers: new Map(), challengeBodies: [], tokenBodies: [] };
  const fetch = async (url, init = {}) => {
    const path = new URL(url, 'http://zoro.test').pathname + new URL(url, 'http://zoro.test').search;
    const auth = init.headers?.Authorization ?? null;
    state.calls.push({ method: init.method, path, auth, credentials: init.credentials, cache: init.cache });
    if (path === '/v1/auth/challenge') {
      state.challengeBodies.push(JSON.parse(init.body));
      state.nonces += 1;
      return json(200, { nonce: `nonce-${state.nonces}`, expires_at: '2026-11-13T06:32:00Z' });
    }
    if (path === '/v1/auth/token') {
      state.tokenBodies.push(JSON.parse(init.body));
      state.tokens += 1;
      return json(200, { access_token: `token-${state.tokens}`, token_type: 'bearer', expires_in: ttl });
    }
    if (auth && state.dead.has(auth.replace('Bearer ', ''))) {
      return json(401, { code: 'token_invalid', message: 'The session token is not valid.', retryable: false }, { 'WWW-Authenticate': 'Bearer' });
    }
    const handler = state.handlers.get(path.split('?')[0]);
    return handler ? handler(init, auth) : json(404, { code: 'not_found', message: 'nope' });
  };
  return { state, fetch };
}

async function pairedClient(server, { now } = {}) {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const keys = await identity.createKeys();
  await identity.commitPairing({ deviceId: 'dev_test', serverName: 'ZORO', platform: 'web', deviceName: 'test', keys });
  const sessions = [];
  const client = new ZoroClient({ baseUrl: 'http://zoro.test', fetch: server.fetch, identity, now, onSession: (state) => sessions.push(state) });
  return { client, identity, sessions };
}

test('the first request signs a challenge, then sends the bearer token', async () => {
  const server = fakeServer();
  server.state.handlers.set('/v1/security/state', (_init, auth) => json(200, { ok: auth }));
  const { client, sessions } = await pairedClient(server);
  const body = await client.securityState();
  assert.equal(body.ok, 'Bearer token-1');
  assert.deepEqual(server.state.calls.map((call) => call.path), ['/v1/auth/challenge', '/v1/auth/token', '/v1/security/state']);
  assert.deepEqual(server.state.challengeBodies, [{ device_id: 'dev_test' }]);
  const tokenBody = server.state.tokenBodies[0];
  assert.equal(tokenBody.device_id, 'dev_test');
  assert.equal(tokenBody.nonce, 'nonce-1');
  assert.match(tokenBody.signature_b64, /^[A-Za-z0-9+/]+=*$/);
  assert.deepEqual(sessions, ['signed_in']);
  // Auth requests carry no bearer token, and nothing uses cookies or the HTTP cache.
  assert.equal(server.state.calls[0].auth, null);
  assert.ok(server.state.calls.every((call) => call.credentials === 'omit' && call.cache === 'no-store'));
});

test('a 401 token_invalid signs in again once and repeats the request', async () => {
  const server = fakeServer();
  let hits = 0;
  server.state.handlers.set('/v1/memory', (_init, auth) => {
    hits += 1;
    return json(200, { items: [], next_cursor: null, used: auth });
  });
  const { client } = await pairedClient(server);
  await client.memories();
  server.state.dead.add('token-1'); // the server restarted or the session was revoked
  const body = await client.memories();
  assert.equal(body.used, 'Bearer token-2');
  assert.equal(server.state.tokens, 2);
  assert.equal(hits, 2); // the dead token never reached the handler
});

test('a 401 that persists after signing in again is reported, not retried forever', async () => {
  const server = fakeServer();
  server.state.handlers.set('/v1/memory', () => json(401, { code: 'token_invalid', message: 'still no', retryable: false }));
  const { client } = await pairedClient(server);
  await assert.rejects(client.memories(), (error) => error instanceof ApiError && error.status === 401 && error.code === 'token_invalid');
  assert.equal(server.state.tokens, 2); // first sign-in, one retry, then stop
  assert.equal(server.state.calls.filter((call) => call.path.startsWith('/v1/memory')).length, 2);
});

test('a revoked device is not retried and asks for pairing', async () => {
  const server = fakeServer();
  server.state.handlers.set('/v1/memory', () => json(401, { code: 'device_revoked', message: 'This device was revoked.', retryable: false }));
  const { client } = await pairedClient(server);
  await assert.rejects(client.memories(), (error) => error.code === 'device_revoked' && error.needsPairing === true);
  assert.equal(server.state.tokens, 1);
});

test('an unpaired browser fails with not_paired before any request is sent', async () => {
  const server = fakeServer();
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const client = new ZoroClient({ baseUrl: 'http://zoro.test', fetch: server.fetch, identity });
  await assert.rejects(client.securityState(), (error) => error.code === 'not_paired' && error.needsPairing);
  assert.equal(server.state.calls.length, 0);
});

test('concurrent requests share one sign-in', async () => {
  const server = fakeServer();
  server.state.handlers.set('/v1/memory', () => json(200, { items: [] }));
  server.state.handlers.set('/v1/devices', () => json(200, { items: [] }));
  const { client } = await pairedClient(server);
  await Promise.all([client.memories(), client.devices(), client.memories()]);
  assert.equal(server.state.tokens, 1);
});

test('a token close to expiry is replaced before it is used', async () => {
  let clock = Date.parse('2026-11-13T06:30:00Z');
  const server = fakeServer({ ttl: 900 });
  server.state.handlers.set('/v1/devices', (_init, auth) => json(200, { used: auth }));
  const { client } = await pairedClient(server, { now: () => new Date(clock) });
  assert.equal((await client.devices()).used, 'Bearer token-1');
  clock += 800_000;
  assert.equal((await client.devices()).used, 'Bearer token-1');
  clock += 80_000; // 880 s: inside the 30 s margin
  assert.equal((await client.devices()).used, 'Bearer token-2');
  assert.ok(client.sessionExpiresAt instanceof Date);
});

test('a turn stream re-authenticates on 401 and then yields the events', async () => {
  const server = fakeServer();
  const bodies = [];
  server.state.handlers.set('/v1/turns', (init) => {
    bodies.push(JSON.parse(init.body));
    return sse([
      { type: 'turn_started', turn_id: 'turn_1', conversation_id: 'conv_1', privacy_mode: 'strict_private' },
      { type: 'turn_completed', turn_id: 'turn_1', message_id: 'msg_1', language: 'en', data_classes: [], cloud_voice_allowed: false, usage: {} },
    ]);
  });
  const { client } = await pairedClient(server);
  await client.ensureSession();
  server.state.dead.add('token-1');
  const events = [];
  for await (const event of await client.startTurn({ input: { text: 'hello' }, client: { platform: 'web' } })) events.push(event.type);
  assert.deepEqual(events, ['turn_started', 'turn_completed']);
  assert.equal(server.state.tokens, 2);
  assert.equal(bodies.length, 1); // the turn was posted once: the dead token never started one
});

test('errors before the stream opens carry the server code (kill switch, conflict)', async () => {
  const server = fakeServer();
  server.state.handlers.set('/v1/turns', () => json(503, { code: 'kill_switch_active', message: 'The kill switch is on.', retryable: false }));
  server.state.handlers.set('/v1/turns/turn_9/resume', () => json(409, { code: 'turn_not_suspended', message: 'This turn is completed.', retryable: false }));
  const { client } = await pairedClient(server);
  await assert.rejects(client.startTurn({ input: { text: 'x' }, client: { platform: 'web' } }), (error) => error.code === 'kill_switch_active' && error.status === 503);
  await assert.rejects(client.resumeTurn('turn_9', { approval: {} }), (error) => error.code === 'turn_not_suspended' && error.status === 409);
});

test('a network failure becomes `unreachable`; an abort stays an abort', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const offline = new ZoroClient({ baseUrl: 'http://zoro.test', identity, fetch: async () => { throw new TypeError('Load failed'); } });
  await assert.rejects(offline.health(), (error) => error instanceof ApiError && error.code === 'unreachable' && error.retryable && error.status === 0);
  const aborting = new ZoroClient({ baseUrl: 'http://zoro.test', identity, fetch: async () => { throw new DOMException('aborted', 'AbortError'); } });
  await assert.rejects(aborting.health(), (error) => error.name === 'AbortError');
});

test('a non-JSON error body (a proxy page) still gives a usable error', async () => {
  const identity = new DeviceIdentity({ store: new MemoryStore() });
  const client = new ZoroClient({ baseUrl: 'http://zoro.test', identity, fetch: async () => new Response('<html>Bad gateway</html>', { status: 502 }) });
  await assert.rejects(client.health(), (error) => error.code === 'http_502' && error.retryable === true);
});

test('signOut forgets the token; the device channel URL carries a fresh one', async () => {
  const server = fakeServer();
  const { client, sessions } = await pairedClient(server);
  const first = new URL(await client.channelUrl());
  assert.equal(first.protocol, 'ws:');
  assert.equal(first.pathname, '/v1/devices/channel');
  assert.equal(first.searchParams.get('token'), 'token-1');
  client.signOut();
  assert.equal(client.sessionExpiresAt, null);
  assert.equal(new URL(await client.channelUrl()).searchParams.get('token'), 'token-2');
  assert.deepEqual(sessions, ['signed_in', 'signed_out', 'signed_in']);
});
