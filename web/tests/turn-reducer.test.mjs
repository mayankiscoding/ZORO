import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  activityRows,
  disconnected,
  EVENT_TYPES,
  initialTurn,
  isActive,
  isFinal,
  orbStateFor,
  reduceAll,
  reduceTurn,
  resumed,
  satellitesFor,
} from '../js/core/turn-reducer.js';

// Event shapes as the real backend sent them (captured with web/tests/e2e.mjs).
const STARTED = { type: 'turn_started', turn_id: 'turn_1', conversation_id: 'conv_1', privacy_mode: 'strict_private' };
const ROUTE = { type: 'route', agents: ['communication'], reason: 'intent communications.draft_message', data_classes: ['personal'], engine: 'deterministic' };
const AGENT_ON = { type: 'agent_started', agent: 'communication', task: 'communications.draft_message' };
const AGENT_OFF = { type: 'agent_finished', agent: 'communication', ok: true, duration_ms: 7 };
const TOOL_ON = { type: 'tool_started', call_id: 'turn_1.p0.f0', tool: 'device.whatsapp.compose', agent: 'communication', risk: 'high' };
const TOOL_OFF = { type: 'tool_finished', call_id: 'turn_1.p0.f0', ok: true, duration_ms: 0, summary: 'WhatsApp is open with your message; tap send.' };
const CARD = { type: 'card', card: { kind: 'message_draft', title: 'Draft', payload: { text: 'On my way' } } };
const APPROVAL = {
  type: 'approval_required',
  approval: { approval_id: 'apr_1', turn_id: 'turn_1', tool: 'device.whatsapp.compose', agent: 'communication', risk: 'high', level: 'confirm', title: 'Prepare a WhatsApp message', summary: 'On my way', details: [], action_digest: 'a'.repeat(64), expires_at: '2026-11-13T06:35:00Z', tainted: false },
};
const SUSPENDED_APPROVAL = { type: 'turn_suspended', turn_id: 'turn_1', reason: 'approval' };
const DEVICE = { type: 'device_action', action: { action_id: 'act_1', turn_id: 'turn_1', tool: 'device.whatsapp.compose', args: { phone: '919876543210', text: 'On my way' }, risk: 'high', expires_at: '2026-11-13T06:31:00Z' } };
const SUSPENDED_DEVICE = { type: 'turn_suspended', turn_id: 'turn_1', reason: 'device_action' };
const TEXT = { type: 'text_delta', text: 'WhatsApp is open with your message; tap send.' };
const COMPLETED = { type: 'turn_completed', turn_id: 'turn_1', message_id: 'msg_1a', language: 'en', data_classes: ['personal'], cloud_voice_allowed: false, usage: { model_calls: 0, tool_calls: 2, cost_usd: '0', duration_ms: 74 } };

const begin = () => initialTurn({ ownerText: 'send a WhatsApp message', modality: 'voice' });

test('every event type of the contract has a reducer case', () => {
  const samples = { turn_started: STARTED, route: ROUTE, agent_started: AGENT_ON, agent_finished: AGENT_OFF, tool_started: TOOL_ON, tool_finished: TOOL_OFF, text_delta: TEXT, card: CARD, approval_required: APPROVAL, device_action: DEVICE, turn_suspended: SUSPENDED_APPROVAL, turn_completed: COMPLETED, error: { type: 'error', code: 'internal_error', message: 'x' } };
  assert.deepEqual(Object.keys(samples).sort(), [...EVENT_TYPES].sort());
  for (const type of EVENT_TYPES) {
    const before = begin();
    const after = reduceTurn(before, samples[type]);
    assert.notEqual(after, before, `${type} changed nothing`);
    assert.equal(after.unknown, 0, `${type} was treated as unknown`);
  }
});

test('the reducer is pure: the input state is never mutated', () => {
  const before = Object.freeze({ ...begin(), agents: Object.freeze([]), tools: Object.freeze([]), cards: Object.freeze([]) });
  reduceAll(before, [STARTED, ROUTE, AGENT_ON, TOOL_ON, CARD, TEXT, TOOL_OFF, AGENT_OFF, COMPLETED]);
  assert.equal(before.phase, 'starting');
  assert.deepEqual(before.agents, []);
});

test('a plain turn: started, routed, worked, answered, completed', () => {
  const turn = reduceAll(begin(), [STARTED, ROUTE, AGENT_ON, AGENT_OFF, { type: 'text_delta', text: 'Saved ' }, { type: 'text_delta', text: 'to memory.' }, COMPLETED]);
  assert.equal(turn.phase, 'completed');
  assert.equal(turn.turnId, 'turn_1');
  assert.equal(turn.conversationId, 'conv_1');
  assert.equal(turn.privacyMode, 'strict_private');
  assert.equal(turn.text, 'Saved to memory.');
  assert.deepEqual(turn.route, { agents: ['communication'], reason: ROUTE.reason, dataClasses: ['personal'], engine: 'deterministic' });
  assert.deepEqual(turn.agents, [{ agent: 'communication', task: AGENT_ON.task, status: 'done', durationMs: 7 }]);
  assert.deepEqual(turn.completed, { messageId: 'msg_1a', language: 'en', dataClasses: ['personal'], cloudVoiceAllowed: false, usage: COMPLETED.usage });
  assert.ok(isFinal(turn) && !isActive(turn));
});

test('approval, then device action, then completion: the full round trip of the real backend', () => {
  let turn = reduceAll(begin(), [STARTED, ROUTE, AGENT_ON, CARD, AGENT_OFF, TOOL_ON, APPROVAL, SUSPENDED_APPROVAL]);
  assert.equal(turn.phase, 'suspended');
  assert.equal(turn.suspendedReason, 'approval');
  assert.equal(turn.approval.approval_id, 'apr_1');
  assert.equal(turn.deviceAction, null);
  assert.equal(turn.tools.length, 1);
  assert.equal(turn.tools[0].status, 'running');
  assert.equal(orbStateFor(turn), 'tool');
  assert.deepEqual(satellitesFor(turn), ['communication']);

  turn = resumed(turn);
  assert.equal(turn.phase, 'running');
  assert.equal(turn.approval, null);

  turn = reduceAll(turn, [DEVICE, SUSPENDED_DEVICE]);
  assert.equal(turn.phase, 'suspended');
  assert.equal(turn.suspendedReason, 'device_action');
  assert.equal(turn.deviceAction.action_id, 'act_1');
  assert.equal(turn.approval, null);

  turn = reduceAll(resumed(turn), [TOOL_OFF, TEXT, COMPLETED]);
  assert.equal(turn.phase, 'completed');
  assert.equal(turn.tools.length, 1);
  assert.deepEqual(turn.tools[0], { callId: 'turn_1.p0.f0', tool: 'device.whatsapp.compose', agent: 'communication', risk: 'high', status: 'done', summary: TOOL_OFF.summary, durationMs: 0 });
  assert.equal(turn.cards.length, 1);
  assert.equal(turn.deviceAction, null);
  assert.equal(turn.suspendedReason, null);
});

test('a refused answer is an error followed by the same request: the turn waits again', () => {
  let turn = reduceAll(begin(), [STARTED, TOOL_ON, APPROVAL, SUSPENDED_APPROVAL]);
  turn = reduceAll(resumed(turn), [{ type: 'error', code: 'approval_digest_mismatch', message: 'The approval did not match.', retryable: true }]);
  assert.equal(turn.phase, 'failed');
  turn = reduceAll(turn, [APPROVAL, SUSPENDED_APPROVAL]);
  assert.equal(turn.phase, 'suspended');
  assert.equal(turn.approval.approval_id, 'apr_1');
  assert.deepEqual(turn.error, { code: 'approval_digest_mismatch', message: 'The approval did not match.', retryable: true });
});

test('a tool started twice (announced again after a resume) keeps one row', () => {
  const turn = reduceAll(begin(), [STARTED, TOOL_ON, TOOL_ON, TOOL_OFF]);
  assert.equal(turn.tools.length, 1);
  assert.equal(turn.tools[0].status, 'done');
});

test('failures: a failed tool and agent are marked, an error event ends the turn', () => {
  const turn = reduceAll(begin(), [
    STARTED,
    { type: 'agent_started', agent: 'finance', task: 'finance.spending_summary' },
    { type: 'tool_started', call_id: 'c1', tool: 'finance.spending_summary', agent: 'finance', risk: 'low' },
    { type: 'tool_finished', call_id: 'c1', ok: false, duration_ms: 20000, summary: null },
    { type: 'agent_finished', agent: 'finance', ok: false, duration_ms: 20010 },
    { type: 'error', code: 'internal_error', message: 'Something went wrong on the ZORO server.', retryable: true },
  ]);
  assert.equal(turn.phase, 'failed');
  assert.equal(turn.tools[0].status, 'failed');
  assert.equal(turn.agents[0].status, 'failed');
  assert.deepEqual(turn.error, { code: 'internal_error', message: 'Something went wrong on the ZORO server.', retryable: true });
  assert.ok(isFinal(turn));
});

test('cancelled is its own phase and clears what was waiting', () => {
  const waiting = reduceAll(begin(), [STARTED, TOOL_ON, APPROVAL, SUSPENDED_APPROVAL]);
  const turn = reduceTurn(waiting, { type: 'error', code: 'cancelled', message: 'Stopped.', retryable: false });
  assert.equal(turn.phase, 'cancelled');
  assert.equal(turn.approval, null);
  assert.equal(turn.suspendedReason, null);
});

test('finished events without a start still leave a row; malformed and unknown events are safe', () => {
  let turn = reduceAll(begin(), [STARTED, { type: 'tool_finished', call_id: 'zz', ok: true, duration_ms: 1, summary: 's' }, { type: 'agent_finished', agent: 'memory', ok: true, duration_ms: 1 }]);
  assert.equal(turn.tools.length, 1);
  assert.equal(turn.agents.length, 1);
  turn = reduceTurn(turn, { type: 'something_new', value: 1 });
  assert.equal(turn.unknown, 1);
  assert.equal(turn.phase, 'running');
  assert.equal(reduceTurn(turn, null), turn);
  assert.equal(reduceTurn(turn, { no: 'type' }), turn);
  assert.equal(reduceTurn(turn, { type: 'card', card: { title: 'no kind' } }), turn);
});

test('the same agent working twice in one turn is one row that is working again', () => {
  const turn = reduceAll(begin(), [STARTED, AGENT_ON, AGENT_OFF, { ...AGENT_ON, task: 'second task' }]);
  assert.equal(turn.agents.length, 1);
  assert.deepEqual(turn.agents[0], { agent: 'communication', task: 'second task', status: 'working', durationMs: null });
});

test('a dropped stream marks a running turn disconnected and leaves finished ones alone', () => {
  const running = reduceAll(begin(), [STARTED, AGENT_ON]);
  const cut = disconnected(running, 'socket closed');
  assert.equal(cut.phase, 'disconnected');
  assert.deepEqual(cut.error, { code: 'unreachable', message: 'socket closed', retryable: true });
  const done = reduceAll(running, [COMPLETED]);
  assert.equal(disconnected(done), done);
  const waiting = reduceAll(running, [APPROVAL, SUSPENDED_APPROVAL]);
  assert.equal(disconnected(waiting), waiting);
});

test('the orb state follows voice first, then the turn, then privacy', () => {
  const idle = initialTurn();
  assert.equal(orbStateFor(idle), 'idle');
  assert.equal(orbStateFor(idle, { privateMode: true }), 'private');
  assert.equal(orbStateFor(idle, { listening: true, privateMode: true }), 'listening');
  assert.equal(orbStateFor(idle, { speaking: true }), 'speaking');
  assert.equal(orbStateFor(idle, { errorFlash: true, privateMode: true }), 'error');

  const starting = begin();
  assert.equal(orbStateFor(starting), 'processing');
  const routed = reduceAll(starting, [STARTED, ROUTE]);
  assert.equal(orbStateFor(routed, { privateMode: true }), 'processing');
  const delegating = reduceAll(routed, [AGENT_ON, { type: 'agent_started', agent: 'finance', task: 't' }]);
  assert.equal(orbStateFor(delegating), 'delegating');
  assert.deepEqual(satellitesFor(delegating), ['communication', 'finance']);
  const tooling = reduceAll(delegating, [TOOL_ON]);
  assert.equal(orbStateFor(tooling), 'tool');
  assert.equal(orbStateFor(tooling, { listening: true }), 'listening'); // barge-in shows at once
  const done = reduceAll(tooling, [TOOL_OFF, AGENT_OFF, COMPLETED]);
  assert.equal(orbStateFor(done, { privateMode: true }), 'private');
  assert.deepEqual(satellitesFor(done), []);
});

test('satellites are capped at six', () => {
  const agents = ['shopping', 'finance', 'memory', 'music', 'fitness', 'vision', 'document', 'automation'];
  const turn = reduceAll(begin(), [STARTED, ...agents.map((agent) => ({ type: 'agent_started', agent, task: 't' }))]);
  assert.equal(satellitesFor(turn).length, 6);
});

test('activity rows carry the status word to show', () => {
  const working = reduceAll(begin(), [STARTED, AGENT_ON, { type: 'agent_started', agent: 'finance', task: 'finance.spending_summary' }]);
  assert.deepEqual(activityRows(working).map((row) => [row.agent, row.status]), [['communication', 'working'], ['finance', 'working']]);

  const waiting = reduceAll(begin(), [STARTED, AGENT_ON, AGENT_OFF, TOOL_ON, APPROVAL, SUSPENDED_APPROVAL]);
  assert.deepEqual(activityRows(waiting), [{ agent: 'communication', task: AGENT_ON.task, status: 'needs_owner', tool: 'device.whatsapp.compose', summary: null }]);

  const done = reduceAll(resumed(waiting), [TOOL_OFF, TEXT, COMPLETED]);
  assert.deepEqual(activityRows(done), [{ agent: 'communication', task: AGENT_ON.task, status: 'done', tool: 'device.whatsapp.compose', summary: TOOL_OFF.summary }]);

  // An agent still open when the turn failed is "couldn't finish", never "working" for ever.
  const failed = reduceAll(working, [{ type: 'error', code: 'internal_error', message: 'x', retryable: true }]);
  assert.deepEqual(activityRows(failed).map((row) => row.status), ['failed', 'failed']);
  const cancelled = reduceAll(working, [{ type: 'error', code: 'cancelled', message: 'Stopped.' }]);
  assert.deepEqual(activityRows(cancelled).map((row) => row.status), ['failed', 'failed']);

  // A tool whose agent never announced itself still gets a row.
  const orphan = reduceAll(begin(), [STARTED, { type: 'tool_started', call_id: 'c9', tool: 'memory.remember', agent: 'memory', risk: 'medium' }]);
  assert.deepEqual(activityRows(orphan), [{ agent: 'memory', task: '', status: 'working', tool: 'memory.remember', summary: null }]);
  assert.deepEqual(activityRows(initialTurn()), []);
});
