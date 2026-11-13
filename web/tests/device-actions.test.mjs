// What the web app does when the server asks the device to act, the approval facts, the
// device channel, and the error-to-sentence mapping.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DeviceChannel } from '../js/core/channel.js';
import { openedResult, openLink, planDeviceAction, refusedResult, safeHttpsUrl, whatsappLink } from '../js/core/device-actions.js';
import { approvalErrorKey, describeError, describeTurnError, pairingErrorKey } from '../js/core/errors.js';
import { Resource } from '../js/core/resource.js';
import en from '../js/i18n/en.js';
import { approvalFacts, secondsUntil } from '../js/ui/approval.js';

const NOW = new Date('2026-11-13T06:30:00Z');
const action = (tool, args = {}, extra = {}) => ({ action_id: 'act_1', tool, args, expires_at: '2026-11-13T06:31:00Z', ...extra });

// Every device tool of docs/architecture/device-contract.md.
const CONTRACT_TOOLS = [
  'device.reminder.create', 'device.calendar.create_event', 'device.calendar.upcoming', 'device.contacts.find', 'device.contacts.save',
  'device.notification.schedule', 'device.location.current', 'device.open_url', 'device.shortcut.run', 'device.music.control',
  'device.photos.search', 'device.health.query', 'device.whatsapp.compose', 'ios.alarm.create', 'ios.timer.start', 'ios.message.compose',
  'ios.home.run_scene', 'mac.applescript.run', 'mac.file.search', 'mac.file.open',
];

test('of the twenty device tools, only the two link tools are attempted; the rest are refused as unsupported', () => {
  const linked = [];
  for (const tool of CONTRACT_TOOLS) {
    const plan = planDeviceAction(action(tool, { url: 'https://example.com/', text: 'hi', phone: '919876543210' }), NOW);
    if (plan.kind === 'link') linked.push(tool);
    else assert.deepEqual(plan, { kind: 'refuse', errorCode: 'unsupported' }, tool);
  }
  assert.deepEqual(linked, ['device.open_url', 'device.whatsapp.compose']);
  assert.deepEqual(planDeviceAction(action('made.up.tool'), NOW), { kind: 'refuse', errorCode: 'unsupported' });
});

test('open_url: https only, with a host, no credentials, no control characters', () => {
  assert.deepEqual(planDeviceAction(action('device.open_url', { url: 'https://example.com/a?b=1#c' }), NOW), { kind: 'link', url: 'https://example.com/a?b=1#c', host: 'example.com', tool: 'device.open_url' });
  for (const [url, code] of [
    ['http://example.com/', 'unsupported'],
    ['javascript:alert(1)', 'unsupported'],
    ['data:text/html,<script>1</script>', 'unsupported'],
    ['shortcuts://run-shortcut?name=x', 'unsupported'], // an app scheme: the iPhone's business
    ['file:///etc/passwd', 'unsupported'],
    ['https://user:pass@example.com/', 'invalid_arguments'],
    ['https://', 'invalid_arguments'],
    ['https://exa mple.com/', 'invalid_arguments'],
    ['https://example.com/\n', 'invalid_arguments'],
    [`https://example.com/${'a'.repeat(2100)}`, 'invalid_arguments'],
  ]) {
    assert.deepEqual(planDeviceAction(action('device.open_url', { url }), NOW), { kind: 'refuse', errorCode: code }, url);
  }
  assert.deepEqual(planDeviceAction(action('device.open_url', {}), NOW), { kind: 'refuse', errorCode: 'invalid_arguments' });
  assert.equal(safeHttpsUrl(42), null);
  assert.equal(safeHttpsUrl('HTTPS://Example.COM'), 'https://example.com/');
});

test('whatsapp.compose builds the wa.me link the owner will tap, and encodes the text', () => {
  assert.equal(whatsappLink({ phone: '919876543210', text: 'On my way' }), 'https://wa.me/919876543210?text=On%20my%20way');
  assert.equal(whatsappLink({ phone: '+91 98765-43210', text: 'दूध & चाय?' }), `https://wa.me/919876543210?text=${encodeURIComponent('दूध & चाय?')}`);
  assert.equal(whatsappLink({ text: 'no number' }), 'https://wa.me/?text=no%20number');
  assert.equal(whatsappLink({ phone: '123', text: 'x' }), null);
  assert.equal(whatsappLink({ phone: '919876543210', text: '' }), null);
  assert.equal(whatsappLink({ phone: '919876543210', text: 'x'.repeat(4001) }), null);
  const plan = planDeviceAction(action('device.whatsapp.compose', { phone: '919876543210', text: 'a#b&c=d' }), NOW);
  assert.equal(plan.kind, 'link');
  assert.equal(plan.host, 'wa.me');
  assert.equal(new URL(plan.url).searchParams.get('text'), 'a#b&c=d');
  assert.deepEqual(planDeviceAction(action('device.whatsapp.compose', { phone: 'x' }), NOW), { kind: 'refuse', errorCode: 'invalid_arguments' });
});

test('an expired action is refused before anything else', () => {
  const late = new Date('2026-11-13T06:31:00Z');
  assert.deepEqual(planDeviceAction(action('device.open_url', { url: 'https://example.com/' }), late), { kind: 'refuse', errorCode: 'expired' });
});

test('results follow DeviceActionResult and never claim more than happened', () => {
  const act = action('ios.alarm.create');
  assert.deepEqual(openedResult(act, NOW), { action_id: 'act_1', ok: true, result: { opened: true }, executed_at: '2026-11-13T06:30:00.000Z' });
  const unsupported = refusedResult(act, 'unsupported', NOW);
  assert.deepEqual(Object.keys(unsupported).sort(), ['action_id', 'capability_status', 'error_code', 'error_message', 'executed_at', 'ok']);
  assert.equal(unsupported.ok, false);
  assert.equal(unsupported.capability_status, 'unavailable');
  assert.match(unsupported.error_message, /iPhone or Mac/);
  for (const code of ['invalid_arguments', 'expired', 'user_cancelled', 'failed']) {
    const result = refusedResult(act, code, NOW);
    assert.equal(result.error_code, code);
    assert.equal('capability_status' in result, false);
    assert.equal('result' in result, false);
    assert.ok(result.error_message.length > 10);
  }
});

test('a link is handed to the browser with noopener, and only when it is a safe https address', () => {
  const calls = [];
  const open = (...args) => {
    calls.push(args);
    return null;
  };
  assert.equal(openLink('https://wa.me/919876543210?text=hi', { open }), true);
  assert.deepEqual(calls, [['https://wa.me/919876543210?text=hi', '_blank', 'noopener,noreferrer']]);
  assert.equal(openLink('javascript:alert(1)', { open }), false);
  assert.equal(openLink('https://example.com/', { open: () => { throw new Error('blocked'); } }), false);
  assert.equal(openLink('https://example.com/', { open: undefined }), false);
  assert.equal(calls.length, 1);
});

test('approval facts: the server rows as sent, plus the summary when the rows do not carry it', () => {
  const details = [{ label: 'Name', value: '+91 98765 43210' }, { label: 'Message', value: 'On my way' }, { label: 'Note', value: 'Opens WhatsApp with this text. You tap send there.' }];
  const rows = approvalFacts({ summary: 'On my way', details }, 'Content');
  assert.deepEqual(rows.map((row) => row.label), ['Name', 'Message', 'Note']); // the summary is already the Message row
  assert.equal(rows[2].stacked, true);
  const withSummary = approvalFacts({ summary: 'Subject: Report\n\nThe report is ready.', details: [{ label: 'To', value: 'priya@example.com' }] }, 'Content');
  assert.deepEqual(withSummary.map((row) => [row.label, row.value]), [['Content', 'Subject: Report\n\nThe report is ready.'], ['To', 'priya@example.com']]);
  assert.deepEqual(approvalFacts({ summary: '', details: null }, 'Content'), []);
  assert.deepEqual(approvalFacts({ summary: 'x', details: [null, { nolabel: 1 }] }, 'Content'), [{ label: 'Content', value: 'x', stacked: false }]);
  assert.equal(secondsUntil('2026-11-13T06:31:45Z', NOW), 105);
  assert.equal(secondsUntil('2026-11-13T06:29:00Z', NOW), 0);
  assert.equal(secondsUntil('not a date', NOW), 0);
});

// ---------------------------------------------------------------- errors -> sentences

test('errors map to a sentence that exists, and to the one action that helps', () => {
  const cases = [
    [{ code: 'unreachable', status: 0 }, { online: true }, 'state.disconnected', 'reconnect', 'disconnected'],
    [{ code: 'unreachable', status: 0 }, { online: false }, 'state.offline', 'reconnect', 'disconnected'],
    [{ code: 'kill_switch_active', status: 503 }, {}, 'state.kill_switch', 'retry', 'error'],
    [{ code: 'device_revoked', status: 401 }, {}, 'state.revoked', 'pair', 'error'],
    [{ code: 'invalid_signature', status: 401 }, {}, 'state.session', 'pair', 'error'],
    [{ code: 'not_paired', status: 401 }, {}, 'state.session', 'pair', 'error'],
    [{ code: 'rate_limited', status: 429 }, {}, 'state.rate_limited', 'retry', 'error'],
    [{ code: 'forbidden', status: 403 }, {}, 'state.forbidden', null, 'error'],
    [{ code: 'memory_not_found', status: 404 }, {}, 'state.not_found', null, 'error'],
    [{ code: 'internal_error', status: 500 }, {}, 'state.server_error', 'retry', 'error'],
    [{ code: 'stream_unsupported', status: 200 }, {}, 'state.stream', null, 'error'],
    [null, {}, 'state.unexpected', null, 'error'],
  ];
  for (const [error, env, key, act, kind] of cases) {
    const view = describeError(error, { online: true, ...env });
    assert.deepEqual([view.key, view.action, view.kind], [key, act, kind], JSON.stringify(error));
    assert.ok(key in en, `${key} is in the catalogue`);
  }
});

test('a turn error event keeps the server sentence (it is already in the owner language)', () => {
  const event = describeTurnError({ code: 'tool_calls', message: 'मैं रुक गया क्योंकि इस अनुरोध में बहुत ज़्यादा क़दम लग रहे थे।', retryable: false });
  assert.equal(event.serverMessage, 'मैं रुक गया क्योंकि इस अनुरोध में बहुत ज़्यादा क़दम लग रहे थे।');
  assert.equal(event.action, null);
  assert.equal(describeTurnError({ code: 'internal_error', message: 'Something went wrong on the ZORO server.', retryable: true }).action, 'retry');
  // A transport failure has no server sentence: the interface string is used.
  const transport = describeTurnError({ code: 'unreachable', status: 0, message: 'The ZORO server could not be reached.', retryable: true });
  assert.equal(transport.serverMessage, undefined);
  assert.equal(transport.key, 'state.disconnected');
});

test('pairing and approval failures each have their own sentence', () => {
  for (const [code, key] of [
    ['pairing_code_incomplete', 'pair.error.incomplete'], ['pairing_code_invalid', 'pair.error.invalid'], ['rate_limited', 'pair.error.rate_limited'],
    ['device_name_invalid', 'pair.error.name'], ['unreachable', 'pair.error.unreachable'], ['webcrypto_unavailable', 'pair.error.crypto'], ['validation_error', 'pair.error.other'],
  ]) {
    assert.equal(pairingErrorKey({ code }), key);
    assert.ok(key in en);
  }
  for (const [code, key] of [
    ['needs_user_presence_key', 'approval.biometric.body'], ['approval_expired', 'approval.expired'], ['invalid_signature', 'approval.error.signature'],
    ['approval_replayed', 'approval.error.gone'], ['turn_not_suspended', 'approval.error.gone'], ['unreachable', 'approval.error.unreachable'],
  ]) {
    assert.equal(approvalErrorKey({ code }), key);
    assert.ok(key in en);
  }
  assert.equal(approvalErrorKey({ code: 'internal_error', status: 500 }), 'state.server_error');
});

// ---------------------------------------------------------------- device channel

class FakeSocket {
  static sockets = [];
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    FakeSocket.sockets.push(this);
  }
  send(text) {
    this.sent.push(JSON.parse(text));
  }
  close(code, reason) {
    this.readyState = 3;
    this.closed = { code, reason };
  }
  open() {
    this.readyState = 1;
    this.onopen?.();
  }
  receive(frame) {
    this.onmessage?.({ data: typeof frame === 'string' ? frame : JSON.stringify(frame) });
  }
  drop(code = 1006) {
    this.readyState = 3;
    this.onclose?.({ code });
  }
}

function channelSetup() {
  FakeSocket.sockets = [];
  const timers = [];
  const seen = { approvals: [], actions: [], statuses: [], posted: [], signOuts: 0 };
  const client = {
    channelUrl: async () => 'ws://zoro.test/v1/devices/channel?token=t',
    postDeviceResult: async (result) => seen.posted.push(result),
    signOut: () => (seen.signOuts += 1),
  };
  const channel = new DeviceChannel({
    client,
    WebSocketImpl: FakeSocket,
    onApproval: (approval) => seen.approvals.push(approval),
    onDeviceAction: (act) => seen.actions.push(act),
    onStatus: (status) => seen.statuses.push(status),
    setTimer: (fn, ms) => timers.push({ fn, ms }) && timers.length,
    clearTimer: () => {},
  });
  const tick = () => new Promise((done) => setTimeout(done, 0));
  return { channel, seen, timers, tick };
}

test('the channel says hello with its two capabilities, pings, and passes frames on', async () => {
  const { channel, seen, timers, tick } = channelSetup();
  channel.start();
  await tick();
  const socket = FakeSocket.sockets[0];
  assert.equal(socket.url, 'ws://zoro.test/v1/devices/channel?token=t');
  socket.open();
  assert.deepEqual(socket.sent, [{ type: 'hello', capabilities: ['device.open_url', 'device.whatsapp.compose'] }]);
  assert.equal(channel.status, 'online');
  const ping = timers.find((timer) => timer.ms === 30_000);
  ping.fn();
  assert.deepEqual(socket.sent.at(-1), { type: 'ping' });

  socket.receive({ type: 'approval_required', approval: { approval_id: 'apr_1', level: 'confirm' } });
  socket.receive({ type: 'device_action', action: { action_id: 'act_1', tool: 'device.open_url' } });
  socket.receive('not json');
  socket.receive({ type: 'approval_required' }); // no approval: ignored
  socket.receive({ type: 'run_script', code: 'alert(1)' }); // unknown: ignored, never acted on
  assert.deepEqual(seen.approvals.map((approval) => approval.approval_id), ['apr_1']);
  assert.deepEqual(seen.actions.map((act) => act.action_id), ['act_1']);

  assert.equal(await channel.sendResult({ action_id: 'act_1', ok: true }), 'sent');
  assert.deepEqual(socket.sent.at(-1), { type: 'device_action_result', result: { action_id: 'act_1', ok: true } });
});

test('a dropped channel reconnects with backoff; results fall back to REST; stop() ends it', async () => {
  const { channel, seen, timers, tick } = channelSetup();
  channel.start();
  await tick();
  FakeSocket.sockets[0].open();
  FakeSocket.sockets[0].drop();
  assert.equal(channel.status, 'offline');
  assert.equal(await channel.sendResult({ action_id: 'act_2', ok: false }), 'posted');
  assert.deepEqual(seen.posted, [{ action_id: 'act_2', ok: false }]);
  const retry = timers.find((timer) => timer.ms === 1000);
  assert.ok(retry, 'first retry after one second');
  retry.fn();
  await tick();
  assert.equal(FakeSocket.sockets.length, 2);
  FakeSocket.sockets[1].drop(1008); // the server refused the token
  assert.equal(seen.signOuts, 1);
  assert.ok(timers.some((timer) => timer.ms === 2000), 'the wait grows');
  channel.stop();
  const before = FakeSocket.sockets.length;
  for (const timer of timers) timer.fn();
  await tick();
  assert.equal(FakeSocket.sockets.length, before); // nothing reconnects after stop()
  assert.equal(channel.status, 'offline');
});

test('without WebSocket the channel is simply off', () => {
  const channel = new DeviceChannel({ client: {}, WebSocketImpl: null });
  assert.equal(channel.supported, false);
  channel.start();
  assert.equal(channel.status, 'offline');
});

// ---------------------------------------------------------------- resources (the four states)

test('a resource goes loading -> ready, keeps the last good value on a failed reload, and drops stale answers', async () => {
  let answer = { items: [1] };
  let fail = null;
  const resource = new Resource(async () => {
    if (fail) throw fail;
    return answer;
  });
  const states = [];
  resource.subscribe((r) => states.push(r.status));
  assert.equal(resource.status, 'idle');
  await resource.refresh();
  assert.deepEqual(states, ['loading', 'ready']);
  assert.deepEqual(resource.value, { items: [1] });

  fail = Object.assign(new Error('x'), { code: 'unreachable' });
  await resource.refresh();
  assert.equal(resource.status, 'error');
  assert.deepEqual(resource.value, { items: [1] }); // still shown, with the error next to it
  assert.equal(resource.error.code, 'unreachable');

  // A slow first load must not overwrite a newer one that finished earlier.
  const gates = [];
  let n = 0;
  const slow = new Resource(() => {
    const mine = ++n;
    return new Promise((done) => gates.push(() => done(`answer ${mine}`)));
  });
  const first = slow.refresh();
  const second = slow.refresh();
  gates[1]();
  await second;
  gates[0]();
  await first;
  assert.equal(slow.value, 'answer 2');
  slow.reset();
  assert.equal(slow.status, 'idle');
  assert.equal(slow.value, null);
});
