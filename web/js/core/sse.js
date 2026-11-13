// Server-Sent Events over a streaming fetch body.
//
// `EventSource` cannot send a POST body or an Authorization header, so turns are read with
// fetch and parsed here. The parser follows the WHATWG event-stream rules: lines end with LF,
// CR or CRLF; `:` starts a comment; a blank line dispatches; several `data:` lines join with
// LF; one leading space after the colon is dropped; an unfinished frame at end of stream is
// discarded. Bytes are decoded incrementally, so a UTF-8 sequence split across two network
// chunks (common with Devanagari) is not corrupted.

export class SSEProtocolError extends Error {
  /** @param {string} message @param {string} [raw] */
  constructor(message, raw) {
    super(message);
    this.name = 'SSEProtocolError';
    this.raw = raw;
  }
}

/** Incremental parser. Feed text with `push`; it returns the frames completed by that text. */
export class SSEParser {
  constructor() {
    this._buffer = '';
    this._event = '';
    this._data = [];
    this._id = undefined;
    this._sawCR = false;
    this._started = false;
  }

  /** @param {string} text
   * @returns {{event: string, data: string, id?: string}[]} */
  push(text) {
    if (!text) return [];
    let chunk = text;
    if (!this._started) {
      this._started = true;
      if (chunk.charCodeAt(0) === 0xfeff) chunk = chunk.slice(1); // byte-order mark
    }
    if (this._sawCR && chunk[0] === '\n') chunk = chunk.slice(1); // CRLF split across chunks
    this._sawCR = false;

    this._buffer += chunk;
    const frames = [];
    let start = 0;
    for (let i = 0; i < this._buffer.length; i += 1) {
      const ch = this._buffer[i];
      if (ch !== '\n' && ch !== '\r') continue;
      const line = this._buffer.slice(start, i);
      if (ch === '\r') {
        if (i + 1 < this._buffer.length) {
          if (this._buffer[i + 1] === '\n') i += 1;
        } else {
          this._sawCR = true; // the LF may be the first character of the next chunk
        }
      }
      start = i + 1;
      const frame = this._line(line);
      if (frame) frames.push(frame);
    }
    this._buffer = this._buffer.slice(start);
    return frames;
  }

  /** @param {string} line */
  _line(line) {
    if (line === '') {
      if (this._data.length === 0) {
        this._event = '';
        return null;
      }
      const frame = { event: this._event || 'message', data: this._data.join('\n') };
      if (this._id !== undefined) frame.id = this._id;
      this._event = '';
      this._data = [];
      return frame;
    }
    if (line[0] === ':') return null; // comment / keep-alive
    const colon = line.indexOf(':');
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? '' : line.slice(colon + 1);
    if (value[0] === ' ') value = value.slice(1);
    if (field === 'event') this._event = value;
    else if (field === 'data') this._data.push(value);
    else if (field === 'id' && !value.includes('\0')) this._id = value;
    // `retry` and unknown fields are ignored: turns are resumed explicitly, never auto-retried.
    return null;
  }
}

/** Parse one frame into a turn event. The backend sends the event model as JSON with its own
 * `type`; the SSE `event:` name must agree with it.
 * @param {{event: string, data: string}} frame */
export function frameToEvent(frame) {
  let parsed;
  try {
    parsed = JSON.parse(frame.data);
  } catch {
    throw new SSEProtocolError('The server sent an event that is not valid JSON.', frame.data.slice(0, 200));
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new SSEProtocolError('The server sent an event that is not an object.', frame.data.slice(0, 200));
  }
  if (typeof parsed.type !== 'string') parsed.type = frame.event;
  if (frame.event !== 'message' && parsed.type !== frame.event) {
    throw new SSEProtocolError(`Event name "${frame.event}" does not match its type "${parsed.type}".`);
  }
  return parsed;
}

/** Read a fetch body (a `ReadableStream<Uint8Array>`) as turn events.
 * @param {ReadableStream<Uint8Array>} body
 * @param {{signal?: AbortSignal}} [options]
 * @returns {AsyncGenerator<Record<string, any>>} */
export async function* readEventStream(body, options = {}) {
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8');
  const parser = new SSEParser();
  const { signal } = options;
  const onAbort = () => {
    reader.cancel().catch(() => {});
  };
  if (signal) {
    if (signal.aborted) onAbort();
    else signal.addEventListener('abort', onAbort, { once: true });
  }
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      for (const frame of parser.push(decoder.decode(value, { stream: true }))) {
        yield frameToEvent(frame);
      }
    }
    for (const frame of parser.push(decoder.decode())) {
      yield frameToEvent(frame);
    }
  } finally {
    if (signal) signal.removeEventListener('abort', onAbort);
    try {
      reader.releaseLock();
    } catch {
      /* the stream was already released */
    }
  }
}
