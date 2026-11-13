import assert from 'node:assert/strict';
import { test } from 'node:test';

import { frameToEvent, readEventStream, SSEParser, SSEProtocolError } from '../js/core/sse.js';

const encoder = new TextEncoder();

function streamOf(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(typeof chunk === 'string' ? encoder.encode(chunk) : chunk);
      controller.close();
    },
  });
}

async function collect(body, options) {
  const events = [];
  for await (const event of readEventStream(body, options)) events.push(event);
  return events;
}

test('one frame as the backend writes it', () => {
  const parser = new SSEParser();
  const frames = parser.push('event: text_delta\ndata: {"type":"text_delta","text":"Done."}\n\n');
  assert.deepEqual(frames, [{ event: 'text_delta', data: '{"type":"text_delta","text":"Done."}' }]);
});

test('a frame split at every possible position gives the same result', () => {
  const wire = 'event: route\ndata: {"type":"route","agents":["finance"],"reason":"r"}\n\nevent: text_delta\ndata: {"type":"text_delta","text":"hi"}\n\n';
  const whole = new SSEParser().push(wire);
  assert.equal(whole.length, 2);
  for (let cut = 1; cut < wire.length; cut += 1) {
    const parser = new SSEParser();
    const frames = [...parser.push(wire.slice(0, cut)), ...parser.push(wire.slice(cut))];
    assert.deepEqual(frames, whole, `cut at ${cut}`);
  }
});

test('CRLF, lone CR and CRLF split across chunks', () => {
  assert.equal(new SSEParser().push('event: a\r\ndata: 1\r\n\r\n').length, 1);
  assert.equal(new SSEParser().push('event: a\rdata: 1\r\r').length, 1);
  const parser = new SSEParser();
  const frames = [...parser.push('event: a\r'), ...parser.push('\ndata: 1\r'), ...parser.push('\n\r'), ...parser.push('\n')];
  assert.deepEqual(frames, [{ event: 'a', data: '1' }]);
});

test('comments, keep-alives and unknown fields are ignored; retry is not honoured', () => {
  const parser = new SSEParser();
  const frames = parser.push(': keep-alive\n\nretry: 10\nfoo: bar\nevent: x\ndata: 1\n\n: again\n\n');
  assert.deepEqual(frames, [{ event: 'x', data: '1' }]);
});

test('several data lines join with a newline; only one leading space is dropped', () => {
  const frames = new SSEParser().push('data: a\ndata:  b\ndata:c\ndata\n\n');
  assert.deepEqual(frames, [{ event: 'message', data: 'a\n b\nc\n' }]);
});

test('an event name without data dispatches nothing and does not leak into the next frame', () => {
  const frames = new SSEParser().push('event: orphan\n\ndata: 1\n\n');
  assert.deepEqual(frames, [{ event: 'message', data: '1' }]);
});

test('id is kept, an id with a NUL is ignored, a byte-order mark is dropped', () => {
  const frames = new SSEParser().push('﻿id: 7\ndata: 1\n\nid: bad\0\ndata: 2\n\n');
  assert.deepEqual(frames, [
    { event: 'message', data: '1', id: '7' },
    { event: 'message', data: '2', id: '7' },
  ]);
});

test('an unfinished frame at the end of the stream is discarded', () => {
  const parser = new SSEParser();
  assert.deepEqual(parser.push('event: text_delta\ndata: {"type":"text_delta","text":"half'), []);
});

test('frameToEvent checks JSON, shape and the event name', () => {
  assert.deepEqual(frameToEvent({ event: 'error', data: '{"type":"error","code":"x","message":"m"}' }), {
    type: 'error',
    code: 'x',
    message: 'm',
  });
  assert.equal(frameToEvent({ event: 'card', data: '{"card":{"kind":"memory"}}' }).type, 'card');
  assert.throws(() => frameToEvent({ event: 'x', data: '{nope' }), SSEProtocolError);
  assert.throws(() => frameToEvent({ event: 'x', data: '[1]' }), SSEProtocolError);
  assert.throws(() => frameToEvent({ event: 'x', data: 'null' }), SSEProtocolError);
  assert.throws(() => frameToEvent({ event: 'route', data: '{"type":"error"}' }), SSEProtocolError);
});

test('readEventStream decodes Devanagari split in the middle of a UTF-8 sequence', async () => {
  const text = 'event: text_delta\ndata: {"type":"text_delta","text":"अलार्म लग गया। ₹1,23,456.50"}\n\n';
  const bytes = encoder.encode(text);
  const expected = [{ type: 'text_delta', text: 'अलार्म लग गया। ₹1,23,456.50' }];
  for (let cut = 1; cut < bytes.length; cut += 1) {
    const events = await collect(streamOf([bytes.slice(0, cut), bytes.slice(cut)]));
    assert.deepEqual(events, expected, `byte cut at ${cut}`);
  }
  const singleBytes = await collect(streamOf([...bytes].map((byte) => Uint8Array.of(byte))));
  assert.deepEqual(singleBytes, expected);
});

test('readEventStream yields a whole turn in order', async () => {
  const wire = [
    'event: turn_started\ndata: {"type":"turn_started","turn_id":"turn_1","conversation_id":"conv_1","privacy_mode":"strict_private"}\n\n',
    'event: text_delta\ndata: {"type":"text_delta","text":"Opened."}\n\n',
    'event: turn_completed\ndata: {"type":"turn_completed","turn_id":"turn_1","message_id":"msg_1","language":"en","data_classes":[],"cloud_voice_allowed":false,"usage":{}}\n\n',
  ];
  const events = await collect(streamOf(wire));
  assert.deepEqual(events.map((event) => event.type), ['turn_started', 'text_delta', 'turn_completed']);
});

test('readEventStream stops when the signal aborts and releases the reader', async () => {
  const controller = new AbortController();
  let cancelled = false;
  const body = new ReadableStream({
    start(streamController) {
      streamController.enqueue(encoder.encode('event: text_delta\ndata: {"type":"text_delta","text":"a"}\n\n'));
    },
    cancel() {
      cancelled = true;
    },
  });
  const seen = [];
  for await (const event of readEventStream(body, { signal: controller.signal })) {
    seen.push(event);
    controller.abort();
  }
  assert.equal(seen.length, 1);
  assert.equal(cancelled, true);
  assert.equal(body.locked, false);
});

test('a malformed event surfaces as a protocol error, not as a silent gap', async () => {
  await assert.rejects(collect(streamOf(['event: text_delta\ndata: {broken\n\n'])), SSEProtocolError);
});
