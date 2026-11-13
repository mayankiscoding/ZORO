// The conversation controller against a scripted client: turns, resume, cancel, device actions
// answered honestly, approvals the web app may and may not sign, history and the sealed cache.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ApiError } from '../js/core/api.js';
import { Conversation } from '../js/core/conversation.js';
import { fromServerMessage, toExchanges } from '../js/core/messages.js';
import { DeviceIdentity, IdentityError } from '../js/core/identity.js';
import { SealedCache } from '../js/core/sealed-cache.js';
import { MemoryStore } from '../js/core/store.js';

const NOW = new Date('2026-11-13T06:30:00Z');

async function* stream(events, { failAfter = null } = {}) {
  let sent = 0;
  for (const event of events) {
    if (failAfter !== null && sent === failAfter) throw new TypeError('network connection was lost');
    sent += 1;
    yield event;
  }
}

const started = (turn = 'turn_1', conv = 'conv_1') => ({ type: 'turn_started', turn_id: turn, conversation_id: conv, privacy_mode: 'strict_private' });
const completed = (turn = 'turn_1') => ({ type: 'turn_completed', turn_id: turn, message_id: `msg_${turn.slice(5)}a`, language: 'en', data_classes: ['personal'], cloud_voice_allowed: false, usage: {} });
const approvalEvent = (level = 'confirm') => ({
  type: 'approval_required',
  approval: { approval_id: 'apr_1', turn_id: 'turn_1', tool: 'device.whatsapp.compose', agent: 'communication', risk: 'high', level, title: 'Prepare a WhatsApp message', summary: 'On my way', details: [], action_digest: 'a'.repeat(64), expires_at: '2026-11-13T06:35:00Z', tainted: false },
});
const deviceEvent = (tool, args = {}) => ({ type: 'device_action', action: { action_id: 'act_1', turn_id: 'turn_1', tool, args, risk: 'low', expires_at: '2026-11-13T06:31:00Z' } });

async function setup(script = {}) {
  const identity = new DeviceIdentity({ store: new MemoryStore(), now: () => NOW });
  const keys = await identity.createKeys();
  await identity.commitPairing({ deviceId: 'dev_1', serverName: 'ZORO', platform: 'ios', deviceName: 'Test', keys });
  const calls = { start: [], resume: [], cancel: [], decide: [], messages: [] };
  const client = {
    async startTurn(request, options) {
      calls.start.push({ request, signal: options?.signal });
      const next = script.start?.shift();
      if (next instanceof Error) throw next;
      return next ?? stream([started(), { type: 'text_delta', text: 'Done.' }, completed()]);
    },
    async resumeTurn(turnId, answer, options) {
      calls.resume.push({ turnId, answer, signal: options?.signal });
      const next = script.resume?.shift();
      if (next instanceof Error) throw next;
      return next ?? stream([{ type: 'text_delta', text: 'Done.' }, completed()]);
    },
    async cancelTurn(turnId) {
      calls.cancel.push(turnId);
      return { turn_id: turnId, status: 'cancelled' };
    },
    async decideApproval(decision) {
      calls.decide.push(decision);
      return script.decide ?? { approval_id: decision.approval_id, owner: 'mcp', approved: decision.approved, status: 'completed', events: [] };
    },
    async allMessages(conversationId) {
      calls.messages.push(conversationId);
      const next = script.messages?.shift();
      if (next instanceof Error) throw next;
      return next ?? [];
    },
  };
  const cache = new SealedCache({ keyStore: new MemoryStore(), cacheStore: new MemoryStore() });
  const conversation = new Conversation({ client, identity, cache, now: () => NOW, context: () => script.context ?? {} });
  const changes = [];
  conversation.subscribe((_state, change) => changes.push(change.type === 'event' ? `event:${change.event.type}` : change.outcome ? `${change.type}:${change.outcome}` : change.type));
  return { conversation, calls, changes, client, identity, cache };
}

test('a turn is posted with the contract shape and folds into the message list', async () => {
  const { conversation, calls, changes } = await setup({ context: { locale: 'hi-IN', timezone: 'Asia/Kolkata', languageHint: 'hinglish', responseLength: 'brief' } });
  const turn = await conversation.send('  kal subah 6 baje alarm laga do  ', { modality: 'voice' });
  const request = calls.start[0].request;
  assert.deepEqual(request, {
    conversation_id: null,
    input: { text: 'kal subah 6 baje alarm laga do', modality: 'voice', language_hint: 'hinglish' },
    client: { platform: 'ios', locale: 'hi-IN', timezone: 'Asia/Kolkata', capabilities: ['device.open_url', 'device.whatsapp.compose'], app_state: { response_length: 'brief' } },
  });
  assert.equal(turn.phase, 'idle'); // folded
  assert.equal(conversation.state.conversationId, 'conv_1');
  assert.deepEqual(conversation.state.messages.map((message) => [message.role, message.text]), [['user', 'kal subah 6 baje alarm laga do'], ['assistant', 'Done.']]);
  assert.equal(conversation.state.messages[0].key, 'turn:turn_1'); // the screen keeps its node across the fold
  assert.equal(conversation.state.last.outcome, 'completed');
  assert.deepEqual(changes.filter((change) => change.startsWith('turn_')), ['turn_begin', 'turn_end:completed']);

  await conversation.send('and again');
  assert.equal(calls.start[1].request.conversation_id, 'conv_1'); // follow-ups keep the conversation
});

test('empty input sends nothing; a private-only browser asks for strict mode', async () => {
  const { conversation, calls } = await setup({ context: { forcePrivate: true } });
  await conversation.send('   ');
  assert.equal(calls.start.length, 0);
  await conversation.send('hello');
  assert.equal(calls.start[0].request.privacy_mode, 'strict_private');
});

test('a device action the web app cannot do is answered as unsupported at once, and the turn goes on', async () => {
  const { conversation, calls } = await setup({
    start: [stream([started(), { type: 'tool_started', call_id: 'c1', tool: 'ios.alarm.create', agent: 'device_control', risk: 'medium' }, deviceEvent('ios.alarm.create', { time: '06:00' }), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'device_action' }])],
    resume: [stream([{ type: 'tool_finished', call_id: 'c1', ok: false, duration_ms: 1, summary: null }, { type: 'text_delta', text: 'This device does not support that.' }, completed()])],
  });
  await conversation.send('set an alarm for 6 am');
  assert.equal(calls.resume.length, 1);
  const result = calls.resume[0].answer.device_result;
  assert.equal(result.action_id, 'act_1');
  assert.equal(result.ok, false);
  assert.equal(result.error_code, 'unsupported');
  assert.equal(result.capability_status, 'unavailable');
  assert.equal(result.executed_at, NOW.toISOString());
  assert.equal(result.result, undefined); // nothing is claimed to have happened
  assert.equal(conversation.state.messages.at(-1).text, 'This device does not support that.');
});

test('a link action waits for the owner; nothing is answered until they choose', async () => {
  const { conversation, calls, changes } = await setup({
    start: [stream([started(), deviceEvent('device.open_url', { url: 'https://example.com/' }), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'device_action' }])],
  });
  await conversation.send('open example.com');
  assert.equal(conversation.state.turn.phase, 'suspended');
  assert.equal(calls.resume.length, 0);
  assert.ok(changes.includes('turn_waiting'));
  await conversation.answerDevice({ action_id: 'act_1', ok: true, result: { opened: true }, executed_at: NOW.toISOString() });
  assert.deepEqual(calls.resume[0].answer, { device_result: { action_id: 'act_1', ok: true, result: { opened: true }, executed_at: NOW.toISOString() } });
  assert.equal(conversation.state.turn.phase, 'idle');
});

test('a confirm approval is signed with the auth key and resumes the turn; decline is signed too', async () => {
  for (const approved of [true, false]) {
    const { conversation, calls } = await setup({ start: [stream([started(), approvalEvent('confirm'), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' }])] });
    await conversation.send('send a message');
    assert.equal(conversation.state.turn.phase, 'suspended');
    await conversation.decide(approved);
    const decision = calls.resume[0].answer.approval;
    assert.equal(calls.resume[0].turnId, 'turn_1');
    assert.equal(decision.approved, approved);
    assert.equal(decision.approval_id, 'apr_1');
    assert.equal(decision.action_digest, 'a'.repeat(64));
    assert.equal(decision.device_id, 'dev_1');
    assert.equal(decision.signed_at, '2026-11-13T06:30:00Z');
    assert.match(decision.signature_b64, /^[A-Za-z0-9+/]+=*$/);
    assert.equal(conversation.state.messages.at(-1).text, 'Done.');
  }
});

test('a biometric approval is never signed here: the turn keeps waiting for the iPhone or Mac', async () => {
  const { conversation, calls } = await setup({ start: [stream([started(), approvalEvent('biometric'), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' }])] });
  await conversation.send('transfer money');
  await assert.rejects(conversation.decide(true), (error) => error instanceof IdentityError && error.code === 'needs_user_presence_key');
  await assert.rejects(conversation.decide(false), (error) => error.code === 'needs_user_presence_key');
  assert.equal(calls.resume.length, 0);
  assert.equal(conversation.state.turn.phase, 'suspended');
  assert.equal(conversation.state.turn.approval.level, 'biometric');
  await assert.rejects(conversation.decidePending(conversation.state.turn.approval, true), (error) => error.code === 'needs_user_presence_key');
  // The owner can withdraw the request from here.
  await conversation.cancel();
  assert.deepEqual(calls.cancel, ['turn_1']);
  assert.equal(conversation.state.turn.phase, 'cancelled');
});

test('an answer the server refuses leaves the request open with the reason', async () => {
  const { conversation } = await setup({
    start: [stream([started(), approvalEvent(), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' }])],
    resume: [stream([{ type: 'error', code: 'invalid_signature', message: 'The signature did not verify.', retryable: true }, approvalEvent(), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' }])],
  });
  await conversation.send('send a message');
  await conversation.decide(true);
  assert.equal(conversation.state.turn.phase, 'suspended');
  assert.equal(conversation.state.turn.approval.approval_id, 'apr_1');
  assert.equal(conversation.state.turn.error.code, 'invalid_signature');
});

test('a resume that conflicts (answered elsewhere, expired) ends the wait and re-reads history', async () => {
  const { conversation, calls } = await setup({
    start: [stream([started(), approvalEvent(), { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' }])],
    resume: [new ApiError({ status: 409, code: 'turn_not_suspended', message: 'This turn is completed, not waiting for an answer.' })],
    messages: [[{ id: 'msg_1u', role: 'user', text: 'send a message', created_at: NOW.toISOString() }, { id: 'msg_1a', role: 'assistant', text: 'Sent from your Mac.', created_at: NOW.toISOString() }]],
  });
  await conversation.send('send a message');
  await conversation.decide(true);
  assert.deepEqual(calls.messages, ['conv_1']);
  assert.equal(conversation.state.turn.phase, 'idle');
  assert.equal(conversation.state.messages.at(-1).text, 'Sent from your Mac.');
});

test('cancel aborts the stream, tells the server, and ignores late events', async () => {
  let release;
  const gate = new Promise((done) => (release = done));
  async function* slow() {
    yield started();
    yield { type: 'agent_started', agent: 'finance', task: 't' };
    await gate;
    yield { type: 'text_delta', text: 'late text' };
    yield completed();
  }
  const { conversation, calls } = await setup({ start: [slow()] });
  const sending = conversation.send('how much did I spend');
  await new Promise((done) => setTimeout(done, 10));
  assert.equal(conversation.busy, true);
  await conversation.cancel();
  assert.equal(calls.start[0].signal.aborted, true);
  assert.deepEqual(calls.cancel, ['turn_1']);
  assert.equal(conversation.state.turn.phase, 'cancelled');
  release();
  await sending;
  assert.equal(conversation.state.turn.phase, 'cancelled');
  assert.equal(conversation.state.turn.text, ''); // the late delta was ignored
  assert.equal(conversation.busy, false);
});

test('sending while a turn runs cancels it first (typed barge-in)', async () => {
  let release;
  const gate = new Promise((done) => (release = done));
  async function* slow() {
    yield started('turn_a');
    await gate;
  }
  const { conversation, calls } = await setup({ start: [slow(), stream([started('turn_b'), { type: 'text_delta', text: 'Second.' }, completed('turn_b')])] });
  const first = conversation.send('first');
  await new Promise((done) => setTimeout(done, 10));
  await conversation.send('second');
  release();
  await first;
  assert.deepEqual(calls.cancel, ['turn_a']);
  assert.deepEqual(conversation.state.messages.map((message) => message.text), ['first', 'second', 'Second.']);
});

test('a stream that drops mid-turn is "disconnected", and history brings the reply', async () => {
  const { conversation, changes } = await setup({
    start: [stream([started(), { type: 'agent_started', agent: 'finance', task: 't' }, completed()], { failAfter: 2 })],
    messages: [[{ id: 'msg_1u', role: 'user', text: 'q', created_at: NOW.toISOString() }, { id: 'msg_1a', role: 'assistant', text: 'The reply from the server.', created_at: NOW.toISOString() }]],
  });
  await conversation.send('q');
  assert.equal(conversation.state.turn.phase, 'disconnected');
  assert.ok(changes.includes('turn_end:disconnected'));
  await conversation.refresh();
  assert.equal(conversation.state.turn.phase, 'idle');
  assert.equal(conversation.state.messages.at(-1).text, 'The reply from the server.');
});

test('a stream that simply ends without a final event is also "disconnected"', async () => {
  const { conversation } = await setup({ start: [stream([started(), { type: 'text_delta', text: 'half' }])] });
  await conversation.send('q');
  assert.equal(conversation.state.turn.phase, 'disconnected');
});

test('errors before the stream opens fail the turn with the server code', async () => {
  for (const [error, code] of [
    [new ApiError({ status: 503, code: 'kill_switch_active', message: 'The kill switch is on.' }), 'kill_switch_active'],
    [new ApiError({ status: 0, code: 'unreachable', message: 'unreachable', retryable: true }), 'unreachable'],
    [new ApiError({ status: 401, code: 'device_revoked', message: 'revoked' }), 'device_revoked'],
  ]) {
    const { conversation, changes } = await setup({ start: [error] });
    await conversation.send('hello');
    assert.equal(conversation.state.turn.phase, 'failed');
    assert.equal(conversation.state.turn.error.code, code);
    assert.equal(conversation.state.turn.ownerText, 'hello'); // kept, so "Try again" can resend it
    assert.ok(changes.includes('turn_end:failed'));
  }
});

test('the last conversation is sealed in the cache and restored without the server', async () => {
  const { conversation, cache, identity, client } = await setup();
  await conversation.send('remember the milk');
  const again = new Conversation({ client, identity, cache, now: () => NOW });
  assert.equal(await again.restore(), true);
  assert.equal(again.state.fromCache, true);
  assert.equal(again.state.conversationId, 'conv_1');
  assert.deepEqual(again.state.messages.map((message) => message.text), ['remember the milk', 'Done.']);
  await again.forgetLocal();
  const empty = new Conversation({ client, identity, cache, now: () => NOW });
  assert.equal(await empty.restore(), false);
});

test('history: a deleted conversation clears the screen; an unreachable server keeps what is shown', async () => {
  const gone = await setup({ messages: [new ApiError({ status: 404, code: 'not_found', message: 'gone' })] });
  await gone.conversation.open('conv_x');
  assert.equal(gone.conversation.state.conversationId, null);
  assert.equal(gone.conversation.state.history, 'ready');

  const offline = await setup({ messages: [new ApiError({ status: 0, code: 'unreachable', message: 'x', retryable: true })] });
  await offline.conversation.send('hello');
  assert.equal(await offline.conversation.refresh(), false);
  assert.equal(offline.conversation.state.history, 'ready');
  assert.equal(offline.conversation.state.historyError.code, 'unreachable');
  assert.equal(offline.conversation.state.messages.length, 2);
});

test('a pending approval from elsewhere goes through the one decision route', async () => {
  const { conversation, calls } = await setup();
  const approval = { approval_id: 'apr_9', action_digest: 'b'.repeat(64), level: 'confirm', expires_at: '2026-11-13T06:35:00Z', turn_id: null, tool: 'automation.run' };
  const result = await conversation.decidePending(approval, false);
  assert.equal(result.owner, 'mcp');
  assert.equal(calls.decide[0].approval_id, 'apr_9');
  assert.equal(calls.decide[0].approved, false);
  assert.equal(calls.resume.length, 0);
});

test('messages pair into exchanges; odd shapes do not break the list', () => {
  const messages = [
    { id: 'a', role: 'assistant', text: 'orphan reply', created_at: 'x' },
    { id: 'u1', role: 'user', text: 'one', created_at: 'x' },
    { id: 'a1', role: 'assistant', text: 'reply one', created_at: 'x', cards: [{ kind: 'memory', payload: {} }, { nope: true }, null] },
    { id: 'u2', role: 'user', text: 'two', created_at: 'x' },
    { id: 'u3', role: 'user', text: 'three', created_at: 'x' },
  ].map(fromServerMessage);
  assert.equal(messages[2].cards.length, 1);
  const exchanges = toExchanges(messages);
  assert.deepEqual(exchanges.map((exchange) => [exchange.owner?.text ?? null, exchange.zoro?.text ?? null]), [[null, 'orphan reply'], ['one', 'reply one'], ['two', null], ['three', null]]);
});
