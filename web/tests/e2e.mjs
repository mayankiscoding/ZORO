// End-to-end test: the web app's own client modules against the real ZORO backend.
//
//   node web/tests/e2e.mjs
//
// Starts the backend from here (uvicorn from backend/.venv on a free local port, a temporary
// SQLite database, no provider keys), makes a pairing code with the backend CLI, pairs with
// `pairDevice`, opens a session with `ZoroClient`, runs turns through `Conversation` and reads
// their events to completion, and completes an approval round trip signed by `DeviceIdentity`.
// Nothing is mocked. The server is stopped and its temporary files are removed at the end.

import assert from 'node:assert/strict';
import { createConnection } from 'node:net';

import { ApiError, ZoroClient } from '../js/core/api.js';
import { DeviceChannel } from '../js/core/channel.js';
import { Conversation } from '../js/core/conversation.js';
import { openedResult, planDeviceAction } from '../js/core/device-actions.js';
import { DeviceIdentity, WEB_CAPABILITIES } from '../js/core/identity.js';
import { pairDevice } from '../js/core/pairing.js';
import { SealedCache } from '../js/core/sealed-cache.js';
import { MemoryStore } from '../js/core/store.js';
import { EVENT_TYPES } from '../js/core/turn-reducer.js';
import { backendAvailable, startBackend } from './helpers/backend.mjs';

const results = [];
const seenEventTypes = new Set();

async function step(name, run) {
  const started = Date.now();
  try {
    const note = await run();
    results.push({ name, ok: true });
    console.log(`ok    ${name} (${Date.now() - started} ms)${note ? `\n      ${note}` : ''}`);
  } catch (error) {
    results.push({ name, ok: false });
    console.log(`FAIL  ${name}\n      ${error?.stack ?? error}`);
    throw error;
  }
}

function portOpen(port) {
  return new Promise((done) => {
    const socket = createConnection({ host: '127.0.0.1', port });
    socket.once('connect', () => {
      socket.destroy();
      done(true);
    });
    socket.once('error', () => done(false));
  });
}

async function main() {
  if (!backendAvailable()) {
    console.log('SKIPPED: backend/.venv is not present, so the backend cannot be started.');
    return 0;
  }
  const backend = await startBackend();
  console.log(`backend started: ${backend.baseUrl} (temporary database in ${backend.workdir})`);
  let failed = false;
  try {
    const identity = new DeviceIdentity({ store: new MemoryStore() });
    const client = new ZoroClient({ baseUrl: backend.baseUrl, identity });
    const cache = new SealedCache({ keyStore: new MemoryStore(), cacheStore: new MemoryStore() });
    const conversation = new Conversation({ client, identity, cache });
    /** Events of the turn in progress, in order. */
    let events = [];
    conversation.subscribe((_state, change) => {
      if (change.type === 'turn_begin') events = [];
      if (change.type === 'event') {
        events.push(change.event);
        seenEventTypes.add(change.event.type);
      }
    });
    const types = () => events.map((event) => event.type);
    let record = null;

    await step('health answers without a session; an unpaired client is refused before any request', async () => {
      const health = await client.health();
      assert.equal(health.status, 'ok');
      await assert.rejects(client.securityState(), (error) => error instanceof ApiError && error.code === 'not_paired');
      return `healthz: ${JSON.stringify(health)}`;
    });

    await step('a wrong pairing code is refused and stores nothing', async () => {
      await assert.rejects(pairDevice({ client, identity, code: 'ZZZZ-9999', deviceName: 'e2e' }), (error) => error.code === 'pairing_code_invalid' && error.status === 400);
      assert.equal(await identity.isPaired(), false);
    });

    await step('pairing with a one-time code from the backend CLI', async () => {
      const code = await backend.pairingCode();
      record = await pairDevice({ client, identity, code, deviceName: 'ZORO web app (e2e)' });
      assert.match(record.deviceId, /^dev_/);
      assert.equal(record.authPrivateKey.extractable, false);
      // The code is single use.
      const second = new DeviceIdentity({ store: new MemoryStore() });
      await assert.rejects(pairDevice({ client, identity: second, code, deviceName: 'again' }), (error) => error.code === 'pairing_code_invalid');
      return `device ${record.deviceId} on "${record.serverName}", registered as platform "${record.platform}"${record.platform === 'web' ? '' : ' (the backend does not know "web" yet, so the fallback was used)'}`;
    });

    await step('challenge -> signature -> token; the session reaches protected routes', async () => {
      const token = await client.ensureSession();
      assert.equal(token.split('.').length, 3); // a JWT
      const state = await client.securityState();
      assert.ok(['strict_private', 'cloud_intelligence'].includes(state.privacy_mode));
      const mine = state.devices.find((device) => device.device_id === record.deviceId);
      assert.ok(mine, 'this device is listed');
      assert.deepEqual([...mine.capabilities].sort(), [...WEB_CAPABILITIES].sort());
      return `privacy mode ${state.privacy_mode}; ${state.devices.length} device(s); session until ${client.sessionExpiresAt.toISOString()}`;
    });

    await step('re-authentication on 401 against the real server', async () => {
      client._token = `${client._token.slice(0, -6)}AAAAAA`; // a token the server will reject
      const before = client._token;
      const devices = await client.devices();
      assert.ok(devices.items.some((device) => device.device_id === record.deviceId));
      assert.notEqual(client._token, before);
      return 'a rejected token was replaced by signing a new challenge, and the request was repeated';
    });

    await step('a turn streams to completion: route, agent, tool, card, text, completed', async () => {
      await conversation.send('remember that my favourite tea is masala chai');
      assert.deepEqual(types().slice(0, 2), ['turn_started', 'route']);
      assert.equal(types().at(-1), 'turn_completed');
      for (const type of ['agent_started', 'agent_finished', 'tool_started', 'tool_finished', 'card', 'text_delta']) assert.ok(types().includes(type), type);
      const reply = conversation.state.messages.at(-1);
      assert.equal(reply.role, 'assistant');
      assert.ok(reply.text.length > 0);
      assert.equal(reply.cards[0].kind, 'memory');
      assert.equal(conversation.state.turn.phase, 'idle');
      return `events: ${types().join(', ')}\n      reply: "${reply.text}"`;
    });

    await step('a turn with no matching intent still completes, with the server saying why', async () => {
      await conversation.send('what is the meaning of life');
      assert.equal(types().at(-1), 'turn_completed');
      return `reply: "${conversation.state.messages.at(-1).text}"`;
    });

    await step('history comes from the server and matches what was streamed', async () => {
      const streamed = conversation.state.messages.map((message) => [message.role, message.text]);
      const list = await client.conversations();
      assert.ok(list.items.some((item) => item.id === conversation.state.conversationId));
      assert.equal(await conversation.refresh(), true);
      assert.deepEqual(conversation.state.messages.map((message) => [message.role, message.text]), streamed);
      assert.equal(conversation.state.messages[1].cards[0].kind, 'memory'); // cards are kept in history
      const restored = new Conversation({ client, identity, cache });
      assert.equal(await restored.restore(), true); // the sealed cache holds the same conversation
      assert.equal(restored.state.messages.length, streamed.length);
      return `${streamed.length} messages in conversation ${conversation.state.conversationId}`;
    });

    await step('approval round trip: suspended -> signed approval -> device link -> completed', async () => {
      await conversation.send('send a WhatsApp message to +919876543210 saying on my way');
      assert.equal(conversation.state.turn.phase, 'suspended');
      assert.deepEqual(types().slice(-2), ['approval_required', 'turn_suspended']);
      const approval = conversation.state.turn.approval;
      assert.equal(approval.level, 'confirm');
      assert.equal(approval.risk, 'high');
      assert.match(approval.action_digest, /^[0-9a-f]{64}$/);
      assert.ok(approval.details.some((row) => row.value === 'On my way'), 'the exact content is in the request');
      const pending = await client.pendingApprovals();
      assert.deepEqual(pending.items.map((item) => item.approval_id), [approval.approval_id]);
      const firstLeg = types().join(', ');

      await conversation.decide(true); // signs zoro-approval-v1|id|digest|1|signed_at with the auth key
      assert.equal(conversation.state.turn.phase, 'suspended');
      assert.deepEqual(types().slice(-2), ['device_action', 'turn_suspended']);
      const action = conversation.state.turn.deviceAction;
      const plan = planDeviceAction(action);
      assert.deepEqual(plan, { kind: 'link', url: 'https://wa.me/919876543210?text=On%20my%20way', host: 'wa.me', tool: 'device.whatsapp.compose' });

      await conversation.answerDevice(openedResult(action)); // the owner tapped "Open WhatsApp"
      assert.equal(types().at(-1), 'turn_completed');
      assert.equal(conversation.state.turn.phase, 'idle');
      assert.deepEqual((await client.pendingApprovals()).items, []);

      // The same signed decision cannot be used again.
      const replay = await identity.signApproval(approval, true);
      await assert.rejects(client.decideApproval(replay), (error) => error.status === 409 && error.code === 'approval_replayed');
      return `first stream: ${firstLeg}\n      approval "${approval.title}" (${approval.tool}, ${approval.risk}, ${approval.level})\n      link offered: ${plan.url}\n      reply: "${conversation.state.messages.at(-1).text}"`;
    });

    await step('declining is signed too, and nothing is handed to the device', async () => {
      await conversation.send('send a WhatsApp message to +919876543210 saying running late');
      assert.equal(conversation.state.turn.approval?.level, 'confirm');
      await conversation.decide(false);
      assert.ok(!types().includes('device_action'));
      assert.equal(types().at(-1), 'turn_completed');
      return `reply: "${conversation.state.messages.at(-1).text}"`;
    });

    await step('a signature over a tampered digest is refused and the request stays open; cancel withdraws it', async () => {
      await conversation.send('send a WhatsApp message to +919876543210 saying see you at 6');
      const approval = conversation.state.turn.approval;
      const forged = await identity.signApproval({ ...approval, action_digest: '0'.repeat(64) }, true);
      const refused = await client.decideApproval(forged);
      assert.equal(refused.status, 'suspended');
      assert.ok(refused.events.some((event) => event.type === 'error' && event.code === 'approval_digest_mismatch'));
      const stillPending = (await client.pendingApprovals()).items.find((item) => item.approval_id === approval.approval_id);
      assert.ok(stillPending, 'the request is still open after the forged decision');
      await conversation.cancel();
      assert.equal(conversation.state.turn.phase, 'cancelled');
      assert.deepEqual((await client.pendingApprovals()).items, []);
    });

    await step('a device tool the web app cannot run ends honestly, not with a timeout', async () => {
      const started = Date.now();
      await conversation.send('set an alarm for 6 am');
      assert.equal(types().at(-1), 'turn_completed');
      assert.ok(Date.now() - started < 10_000);
      return `events: ${types().join(', ')}\n      reply: "${conversation.state.messages.at(-1).text}"`;
    });

    await step('opening a link: offered as a link, answered after the tap', async () => {
      await conversation.send('open https://example.com');
      const action = conversation.state.turn.deviceAction;
      assert.equal(action?.tool, 'device.open_url');
      assert.equal(planDeviceAction(action).url, 'https://example.com/');
      await conversation.answerDevice(openedResult(action));
      assert.equal(types().at(-1), 'turn_completed');
      return `reply: "${conversation.state.messages.at(-1).text}"`;
    });

    await step('the device channel: hello over WebSocket makes this device online', async () => {
      const statuses = [];
      const channel = new DeviceChannel({ client, onStatus: (status) => statuses.push(status) });
      channel.start();
      const deadline = Date.now() + 10_000;
      let online = false;
      while (!online && Date.now() < deadline) {
        await new Promise((done) => setTimeout(done, 150));
        if (channel.status !== 'online') continue;
        const devices = await client.devices();
        online = devices.items.find((device) => device.device_id === record.deviceId)?.online === true;
      }
      channel.stop();
      assert.equal(online, true, `statuses: ${statuses.join(', ')}`);
      await new Promise((done) => setTimeout(done, 300));
      const after = await client.devices();
      assert.equal(after.items.find((device) => device.device_id === record.deviceId).online, false);
      return `statuses: ${statuses.join(' -> ')}`;
    });

    await step('read-only spaces answer in the documented shapes; memory can be deleted', async () => {
      const finance = await client.financeSummary('this_month');
      assert.match(finance.spent, /^\d+\.\d{2}$/); // money is a decimal string
      assert.equal(typeof finance.period.label_hi, 'string');
      const basket = await client.basket();
      assert.ok('basket' in basket);
      const memories = await client.memories();
      const saved = memories.items.find((item) => item.text.includes('masala chai'));
      assert.ok(saved, 'the remembered fact is listed');
      assert.equal(await client.deleteMemory(saved.id), null);
      assert.ok(!(await client.memories()).items.some((item) => item.id === saved.id));
      await assert.rejects(client.deleteMemory(saved.id), (error) => error.status === 404);
      return `finance ${finance.period.label_en}: spent ${finance.spent}, ${finance.transactions} transactions; basket: ${basket.basket ? 'present' : 'none'}`;
    });

    await step('security changes are refused without the approval key', async () => {
      // The web app has no user-presence key. A proof signed with the auth key must not be accepted.
      const signedAt = new Date(Math.floor(Date.now() / 1000) * 1000);
      const stamp = `${signedAt.toISOString().slice(0, 19)}Z`;
      const proof = { device_id: record.deviceId, signed_at: stamp, signature_b64: await identity.sign(`zoro-action-v1|set_privacy_mode|cloud_intelligence|${stamp}`), key: 'approval' };
      await assert.rejects(client.json('PUT', '/v1/security/privacy-mode', { body: { mode: 'cloud_intelligence', proof } }), (error) => error.status === 403 && error.code === 'proof_invalid');
      assert.equal((await client.securityState()).privacy_mode, 'strict_private');
    });

    await step('deleting the conversation removes it from the server', async () => {
      const id = conversation.state.conversationId;
      await client.deleteConversation(id);
      assert.ok(!(await client.conversations()).items.some((item) => item.id === id));
      await conversation.refresh();
      assert.equal(conversation.state.conversationId, null);
    });

    await step('every event type of the contract was seen on the wire', async () => {
      const missing = EVENT_TYPES.filter((type) => !seenEventTypes.has(type));
      // `error` only appears inside a decision result here (the forged digest), not on a stream.
      assert.deepEqual(missing.filter((type) => type !== 'error'), []);
      return `seen on streams: ${[...seenEventTypes].sort().join(', ')}${missing.length ? `\n      not seen on a stream: ${missing.join(', ')}` : ''}`;
    });
  } catch {
    failed = true;
  } finally {
    await backend.stop();
  }
  const stopped = !(await portOpen(backend.port));
  console.log(`backend stopped: ${stopped ? 'yes' : 'NO, the port still answers'}`);
  const passed = results.filter((result) => result.ok).length;
  console.log(`\ne2e: ${passed} passed, ${results.length - passed} failed, ${results.length} steps run`);
  return failed || !stopped ? 1 : 0;
}

process.exit(await main());
