// Shared interface pieces: state views, section titles, facts, badges, toasts, dialogs.
// Each is a plain function returning DOM nodes; text is always inserted as text.

import { describeError } from '../core/errors.js';
import { formatMoney, formatTime, isStale } from '../core/format.js';
import { h, onAction } from './dom.js';
import { icon } from './icons.js';

/** One sentence, one optional action, left-aligned.
 * @param {'empty' | 'loading' | 'error' | 'disconnected'} kind
 * @param {string} message
 * @param {{label: string, run: () => any} | null} [action]
 * @param {{plain?: boolean}} [options] */
export function stateView(kind, message, action = null, { plain = false } = {}) {
  const mark =
    kind === 'loading'
      ? h('span.spinner', { 'aria-hidden': 'true' })
      : icon(kind === 'error' ? 'alert' : kind === 'disconnected' ? 'cloud' : 'info', { size: 20 });
  const node = h(
    `div.state.state--${kind}${plain ? '.state--plain' : ''}`,
    { role: kind === 'error' || kind === 'disconnected' ? 'alert' : 'status' },
    h('div.state-line', null, mark, h('p', { text: message })),
  );
  if (action) {
    node.append(onAction(h('button.btn.btn--secondary.btn--small', { type: 'button', text: action.label }), action.run));
  }
  return node;
}

/** A state view for a failed request: says what happened and offers the one fitting action.
 * @param {(key: string, params?: any) => string} t
 * @param {any} error
 * @param {{retry?: () => any, pair?: () => any, fallbackKey?: string, plain?: boolean}} [actions] */
export function errorView(t, error, { retry, pair, fallbackKey, plain } = {}) {
  const view = describeError(error);
  const useFallback = fallbackKey && view.key === 'state.unexpected';
  const message = useFallback ? t(fallbackKey) : t(view.key);
  let action = null;
  if (view.action === 'pair' && pair) action = { label: t('state.pair_again'), run: pair };
  else if (view.action === 'reconnect' && retry) action = { label: t('common.reconnect'), run: retry };
  else if (retry && (view.action === 'retry' || useFallback)) action = { label: t('common.try_again'), run: retry };
  return stateView(view.kind, message, action, { plain });
}

/** A section whose title hangs from a hairline.
 * @param {string} title @param {{detail?: string, action?: Node, level?: 2 | 3}} [options] */
export function section(title, { detail, action, level = 2 } = {}, ...children) {
  return h(
    'section.section',
    null,
    h('div.section-title', null, h(`h${level}.t-heading`, { text: title }), detail ? h('span.t-detail', { text: detail }) : null, action ?? null),
    ...children,
  );
}

/** Label / value rows. Values wrap; they are never truncated.
 * @param {{label: string, value: string | Node | null | undefined, stacked?: boolean, mono?: boolean}[]} items
 * @param {{wide?: boolean}} [options] `wide` gives long labels the room (short values, as in settings) */
export function facts(items, { wide = false } = {}) {
  return h(
    `dl.facts${wide ? '.facts--wide' : ''}`,
    null,
    items
      .filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
      .map((item) =>
        h(
          `div.fact${item.stacked ? '.fact--stacked' : ''}`,
          null,
          h('dt', { text: item.label }),
          h(`dd${item.mono ? '.mono' : ''}`, null, item.value),
        ),
      ),
  );
}

/** @param {string} text @param {'neel' | 'mor' | 'genda' | 'lac' | 'moon' | null} [tone] */
export function badge(text, tone = null) {
  return h(`span.badge${tone ? `.badge--${tone}` : ''}`, { text });
}

const RISK_TONE = { low: null, medium: 'neel', high: 'genda', critical: 'lac' };

export function riskBadge(t, risk) {
  return badge(t(`risk.${['low', 'medium', 'high', 'critical'].includes(risk) ? risk : 'medium'}`), RISK_TONE[risk] ?? 'neel');
}

const STATUS_TONE = { working: 'neel', needs_owner: 'genda', done: 'mor', failed: 'lac', waiting: null };

/** Agent status as words, never colour alone. */
export function statusBadge(t, status) {
  const known = status in STATUS_TONE ? status : 'working';
  return badge(t(`agent.status.${known}`), STATUS_TONE[known]);
}

/** Money from a decimal string. A value that is not an amount shows as "Not reported", never 0.
 * @param {(key: string) => string} t @param {unknown} amount @param {{hero?: boolean}} [options] */
export function money(t, amount, { hero = false } = {}) {
  const text = formatMoney(amount);
  return h(`span.t-amount${hero ? '.t-amount--hero' : ''}`, { text: text ?? t('common.not_reported') });
}

/** "From Instamart, checked 4:12 pm" with the stale-price warning after 30 minutes.
 * @param {(key: string, params?: any) => string} t
 * @param {{source?: string | null, at?: string | null, warnStale?: boolean}} stamp @param {Date} [now] */
export function sourceLine(t, { source, at, warnStale = true }, now = new Date()) {
  if (!source || !at) return null;
  const stale = warnStale && isStale(at, now);
  return h(
    `p.source-line${stale ? '.source-line--stale' : ''}`,
    null,
    stale ? icon('clock', { size: 14 }) : null,
    h('span', { text: t('card.source', { source: readableSource(source), time: formatTime(at, t.lang) }) }),
    stale ? h('span', { text: t('card.stale') }) : null,
  );
}

/** "swiggy_instamart:search_products" -> "Swiggy instamart". The id is the server's; only its
 * shape is made readable. @param {string} source */
export function readableSource(source) {
  const name = String(source).split(':')[0].replace(/[_-]+/g, ' ').trim();
  return name ? name[0].toUpperCase() + name.slice(1) : String(source);
}

// ---------------------------------------------------------------- toasts

/** @param {HTMLElement} host a live region */
export function createToaster(host) {
  return function toast(message, { action = null, ms = 4500 } = {}) {
    const node = h('div.toast', null, h('span', { text: message }));
    if (action) {
      node.append(
        h('button.btn.btn--link', {
          type: 'button',
          text: action.label,
          on: {
            click: () => {
              node.remove();
              action.run();
            },
          },
        }),
      );
    }
    host.append(node);
    while (host.children.length > 2) host.firstElementChild.remove();
    if (ms > 0) setTimeout(() => node.remove(), ms);
    return node;
  };
}

// ---------------------------------------------------------------- dialogs

/** A bottom sheet on a native <dialog>: focus is trapped and returned by the browser, Escape
 * closes it. @param {string} labelledBy id of the heading inside */
export function createSheet(labelledBy) {
  const dialog = h('dialog.sheet', { 'aria-labelledby': labelledBy });
  const body = h('div.sheet-body');
  dialog.append(body);
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close('dismiss'); // a tap on the backdrop
  });
  return { dialog, body };
}

/** Ask the owner to confirm something that cannot be undone.
 * @returns {Promise<boolean>} */
export function confirmDialog(t, { message, confirmLabel, danger = true }) {
  return new Promise((resolve) => {
    const { dialog, body } = createSheet('confirm-title');
    dialog.setAttribute('role', 'alertdialog');
    body.append(
      h('p#confirm-title.zoro-body', { text: message }),
      h(
        'div.btn-stack',
        null,
        h(`button.btn.btn--block.${danger ? 'btn--danger' : 'btn--primary'}`, { type: 'button', text: confirmLabel, on: { click: () => dialog.close('confirm') } }),
        h('button.btn.btn--block.btn--secondary', { type: 'button', text: t('common.cancel'), autofocus: true, on: { click: () => dialog.close('cancel') } }),
      ),
    );
    dialog.addEventListener('close', () => {
      const confirmed = dialog.returnValue === 'confirm';
      dialog.remove();
      resolve(confirmed);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

/** A labelled radio group shown as chips.
 * @param {{legend: string, name: string, value: string, options: {value: string, label: string}[],
 *   onChange: (value: string) => void}} config */
export function segmented({ legend, name, value, options, onChange }) {
  return h(
    'fieldset.segmented',
    null,
    h('legend', { text: legend }),
    options.map((option) =>
      h(
        'label',
        null,
        h('input', {
          type: 'radio',
          name,
          value: option.value,
          checked: option.value === value,
          on: { change: (event) => event.target.checked && onChange(option.value) },
        }),
        h('span', { text: option.label }),
      ),
    ),
  );
}

/** An on/off switch with its label.
 * @param {{label: string, note?: string, checked: boolean, onChange: (checked: boolean) => void}} config */
export function switchRow({ label, note, checked, onChange }) {
  const id = `sw-${Math.random().toString(36).slice(2, 9)}`;
  const control = h('button.switch', { type: 'button', role: 'switch', 'aria-checked': String(checked), 'aria-labelledby': id });
  control.addEventListener('click', () => {
    const next = control.getAttribute('aria-checked') !== 'true';
    control.setAttribute('aria-checked', String(next));
    onChange(next);
  });
  return h('div.switch-row', null, h('div', null, h('p', { id, text: label }), note ? h('p.field-hint', { text: note }) : null), control);
}
