// Messages of a conversation as the screens use them: the server's `Message` made safe to
// render, paired into exchanges (the owner's words and ZORO's reply), and errors as plain facts.

import { ApiError } from './api.js';

/** @typedef {{id: string, key: string, role: 'user'|'assistant', text: string, language: string,
 *   createdAt: string, agents: string[], cards: {kind: string, title: string|null, payload: any}[]}} ChatMessage */

/** @param {any} message a `Message` of the contract @returns {ChatMessage} */
export function fromServerMessage(message) {
  return {
    id: String(message.id),
    key: String(message.id),
    role: message.role === 'user' ? 'user' : 'assistant',
    text: String(message.text ?? ''),
    language: message.language ?? 'en',
    createdAt: message.created_at ?? new Date(0).toISOString(),
    agents: Array.isArray(message.agents) ? message.agents : [],
    cards: Array.isArray(message.cards)
      ? message.cards
          .filter((card) => card && typeof card.kind === 'string')
          .map((card) => ({ kind: card.kind, title: card.title ?? null, payload: card.payload ?? {} }))
      : [],
  };
}

/** Pair messages into exchanges (the owner's words and ZORO's reply), oldest first.
 * @param {ChatMessage[]} messages */
export function toExchanges(messages) {
  const exchanges = [];
  let open = null;
  for (const message of messages) {
    if (message.role === 'user') {
      open = { key: message.key, owner: message, zoro: null };
      exchanges.push(open);
    } else if (open && !open.zoro) {
      open.zoro = message;
      open = null;
    } else {
      exchanges.push({ key: message.key, owner: null, zoro: message });
    }
  }
  return exchanges;
}

/** An error as plain facts for the screen. */
export function errorState(error) {
  if (error instanceof ApiError) {
    return { code: error.code, message: error.message, retryable: error.retryable, status: error.status };
  }
  if (error && typeof error.code === 'string') return { code: error.code, message: error.message ?? '', retryable: false, status: 0 };
  return { code: 'unexpected', message: error?.message ?? '', retryable: true, status: 0 };
}
