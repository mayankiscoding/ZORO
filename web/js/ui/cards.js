// Result cards: one renderer per `UICard.kind` the backend emits, and a generic fallback that
// shows any other payload as it was sent. Nothing is invented: a value the server did not send
// is shown as "Not reported" or "Not available", never as zero, and every price carries its
// source and time. Remote images are not loaded (the web app sends nothing to third parties).

import { safeHttpsUrl } from '../core/device-actions.js';
import { formatDate, formatMoney, formatTime, formatWhen } from '../core/format.js';
import { badge, facts, money, readableSource, sourceLine } from './components.js';
import { h } from './dom.js';
import { icon } from './icons.js';

const MAX_PRODUCTS = 6;
const MAX_TRANSACTIONS = 8;
const MAX_ROWS = 12;

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function list(value) {
  return Array.isArray(value) ? value : [];
}

function cardShell(title, ...children) {
  return h('article.card', null, title ? h('div.card-title', null, h('h3.t-heading', { text: title })) : null, ...children);
}

function periodLabel(period, lang) {
  if (!isObject(period)) return null;
  return (lang === 'hi' ? period.label_hi : period.label_en) || period.label_en || null;
}

// ---------------------------------------------------------------- products

function stockWord(t, inStock) {
  if (inStock === true) return h('span.status--good', { text: t('card.products.in_stock') });
  if (inStock === false) return h('span.status--bad', { text: t('card.products.out_of_stock') });
  return h('span', { text: t('card.products.stock_unknown') });
}

function productsCard(t, card, now) {
  const products = list(card.payload.products);
  if (products.length === 0) return genericCard(t, card);
  const lowest = formatMoney(card.payload.lowest_price);
  const shown = products.slice(0, MAX_PRODUCTS);
  const body = shown.map((product) => {
    const variant = list(product.variants)[0] ?? {};
    const price = formatMoney(variant.price);
    const isLowest = Boolean(price && lowest && price === lowest);
    return h(
      'div.product',
      null,
      h(
        'div.product-head',
        null,
        h('p.product-name', { text: `${product.index ? `${product.index}. ` : ''}${product.name ?? ''}` }),
        price ? h('span.t-amount', { text: price }) : h('span.t-detail', { text: t('card.products.price_unknown') }),
      ),
      h(
        'div.product-meta',
        null,
        product.brand ? h('span', { text: product.brand }) : null,
        variant.label ? h('span', { text: variant.label }) : null,
        variant.unit_price ? h('span', { text: variant.unit_price }) : null,
        formatMoney(variant.mrp) && formatMoney(variant.mrp) !== price ? h('span', { text: t('card.products.mrp', { price: formatMoney(variant.mrp) }) }) : null,
        stockWord(t, variant.in_stock),
        isLowest ? badge(t('card.products.lowest'), 'mor') : null,
      ),
      sourceLine(t, { source: product.source ?? product.provider, at: product.retrieved_at }, now),
    );
  });
  const more = products.length - shown.length;
  return cardShell(card.title, ...body, more > 0 ? h('p.t-caption', { text: t.plural('card.products.more', more) }) : null);
}

// ---------------------------------------------------------------- basket

export function basketBody(t, basket, now) {
  const items = list(basket.items);
  const rows = items.map((item) => {
    const price = formatMoney(item.unit_price);
    return h(
      'div.product',
      null,
      h(
        'div.product-head',
        null,
        h('p.product-name', { text: item.name ?? '' }),
        price ? h('span.t-amount', { text: price }) : h('span.t-detail', { text: t('card.basket.no_price') }),
      ),
      h(
        'div.product-meta',
        null,
        item.brand ? h('span', { text: item.brand }) : null,
        item.size ? h('span', { text: item.size }) : null,
        h('span', { text: t('card.basket.quantity', { count: item.quantity ?? 1 }) }),
      ),
      price ? sourceLine(t, { source: item.price_source, at: item.price_at }, now) : null,
    );
  });
  const priced = Number.isInteger(basket.priced_items) ? basket.priced_items : null;
  const total = formatMoney(basket.known_total);
  return [
    ...rows,
    priced !== null && priced > 0 && total
      ? h(
          'div.product',
          null,
          h('div.product-head', null, h('p.product-name', { text: t('card.basket.known_total') }), h('span.t-amount', { text: total })),
          priced < items.length ? h('p.t-caption', { text: t('card.basket.priced', { priced, total: items.length }) }) : null,
        )
      : null,
  ];
}

function basketCard(t, card, now) {
  const basket = card.payload;
  const items = list(basket.items);
  return h(
    'article.card',
    null,
    h('div.card-title', null, h('h3.t-heading', { text: card.title || basket.name || '' }), h('span.t-detail', { text: t.plural('card.basket.items', items.length) })),
    ...basketBody(t, basket, now),
  );
}

// ---------------------------------------------------------------- basket comparison

/** The comparison as a table: one row per basket item, one column per store. A store that lacks
 * an item says "Not available" and can never be marked lowest. Totals are the server's.
 * @returns {Node[]} */
export function comparisonBody(t, comparison, now) {
  const providers = list(comparison.providers);
  if (comparison.cheapest_reason === 'empty_basket' || providers.length === 0) {
    return [h('p.note', { text: t('card.compare.empty') })];
  }
  const itemNames = new Map();
  for (const provider of providers) {
    for (const line of [...list(provider.lines), ...list(provider.substitutes), ...list(provider.missing)]) {
      if (line?.item_id && !itemNames.has(line.item_id)) itemNames.set(line.item_id, line.name ?? line.item_id);
    }
  }
  const cell = (provider, itemId) => {
    const line = list(provider.lines).find((entry) => entry.item_id === itemId);
    const amount = line ? formatMoney(line.line_total) : null;
    if (amount) {
      const stale = list(provider.stale_items).includes(itemId);
      return h('td', null, amount, stale ? h('span.cell-note.status--warn', { text: t('card.stale') }) : null);
    }
    return h('td.cell-missing', { text: t('card.compare.unavailable') });
  };
  const head = h('tr', null, h('th', { scope: 'col', text: t('card.compare.store') }), providers.map((provider) => h('th', { scope: 'col', text: provider.title || readableSource(provider.provider) })));
  const body = [...itemNames].map(([itemId, name]) => h('tr', null, h('th', { scope: 'row', text: name }), providers.map((provider) => cell(provider, itemId))));
  const feeRow = h(
    'tr',
    null,
    h('th', { scope: 'row', text: t('card.compare.fees') }),
    providers.map((provider) =>
      provider.fees_known && formatMoney(provider.fee_total) ? h('td', { text: formatMoney(provider.fee_total) }) : h('td.cell-missing', { text: t('card.compare.fees_unknown') }),
    ),
  );
  const anyDiscount = providers.some((provider) => list(provider.discounts).length > 0);
  const discountRow = anyDiscount
    ? h('tr', null, h('th', { scope: 'row', text: t('card.compare.discounts') }), providers.map((provider) => h('td', { text: list(provider.discounts).length ? `−${formatMoney(provider.discount_total) ?? ''}` : '' })))
    : null;
  const totalRow = h(
    'tr',
    null,
    h('th', { scope: 'row', text: t('card.compare.payable') }),
    providers.map((provider) => {
      const missing = list(provider.missing).length;
      const payable = formatMoney(provider.final_payable);
      const isLowest = comparison.cheapest_provider && provider.provider === comparison.cheapest_provider && missing === 0 && payable;
      return h(
        'td',
        null,
        payable ?? formatMoney(provider.item_total) ?? t('card.compare.unavailable'),
        isLowest ? h('span.cell-note.status--good', { text: t('card.compare.lowest') }) : null,
        missing > 0 ? h('span.cell-note', { text: t.plural('card.compare.missing', missing) }) : null,
      );
    }),
  );
  const reasonKey = { no_complete_provider: 'card.compare.none_complete', fees_unknown: 'card.compare.fees_note', tie: 'card.compare.tie' }[comparison.cheapest_reason];
  return [
    h('div.table-wrap', { tabindex: '0', role: 'group', 'aria-label': t('card.compare.title') }, h('table.table', null, h('thead', null, head), h('tbody', null, body, feeRow, discountRow), h('tfoot', null, totalRow))),
    reasonKey ? h('p.note', { text: t(reasonKey) }) : null,
    comparison.computed_at ? h('p.source-line', { text: t('card.compare.computed', { time: formatTime(comparison.computed_at, t.lang) }) }) : null,
  ];
}

function comparisonCard(t, card, now) {
  return cardShell(t('card.compare.title'), ...comparisonBody(t, card.payload, now));
}

// ---------------------------------------------------------------- finance

/** Spent / received / net and the top categories. Shares are the server's `share_pct`; the bar
 * width only draws that number. @returns {Node[] | null} */
export function financeBody(t, summary) {
  if (!formatMoney(summary.spent)) return null;
  const categories = list(summary.top_categories);
  return [
    h(
      'div.totals',
      null,
      h('div', null, h('p.total-label', { text: t('card.finance.spent') }), money(t, summary.spent, { hero: true })),
      h('div', null, h('p.total-label', { text: t('card.finance.received') }), money(t, summary.received)),
      h('div', null, h('p.total-label', { text: t('card.finance.net') }), money(t, summary.net)),
    ),
    Number.isInteger(summary.transactions) ? h('p.t-caption', { text: t.plural('card.finance.transactions', summary.transactions) }) : null,
    categories.length
      ? h(
          'div.bars',
          null,
          categories.map((category) => {
            const share = Number.parseFloat(category.share_pct);
            const fill = h('span.bar-fill');
            fill.style.width = `${Number.isFinite(share) ? Math.max(0, Math.min(100, share)) : 0}%`;
            return h(
              'div',
              null,
              h('div.bar-head', null, h('span', { text: category.name ?? category.category ?? '' }), h('span.t-amount', { text: formatMoney(category.amount) ?? t('common.not_reported') })),
              h('div.bar-track', { role: 'img', 'aria-label': t('card.finance.share', { percent: category.share_pct ?? '0' }) }, fill),
            );
          }),
        )
      : null,
  ];
}

function financeCard(t, card) {
  const body = financeBody(t, card.payload);
  if (!body) return genericCard(t, card);
  const label = periodLabel(card.payload.period, t.lang);
  return cardShell(label ? `${t('spaces.finance')}: ${label}` : card.title, ...body);
}

function transactionsCard(t, card) {
  const items = list(card.payload.items);
  if (items.length === 0 && !formatMoney(card.payload.total_debit)) return genericCard(t, card);
  const shown = items.slice(0, MAX_TRANSACTIONS);
  const count = Number.isInteger(card.payload.count) ? card.payload.count : items.length;
  return cardShell(
    card.title,
    h(
      'div.totals',
      null,
      h('div', null, h('p.total-label', { text: t('card.finance.spent') }), money(t, card.payload.total_debit)),
      h('div', null, h('p.total-label', { text: t('card.finance.received') }), money(t, card.payload.total_credit)),
    ),
    h(
      'div',
      null,
      shown.map((item) =>
        h(
          'div.product',
          null,
          h(
            'div.product-head',
            null,
            h('p.product-name', { text: item.counterparty || item.narration || '' }),
            h('span.t-amount', { text: `${item.direction === 'credit' ? '+' : ''}${formatMoney(item.amount) ?? t('common.not_reported')}` }),
          ),
          h('div.product-meta', null, item.date ? h('span', { text: formatDate(`${item.date}T00:00:00`, t.lang) }) : null, item.category ? h('span', { text: item.category }) : null),
        ),
      ),
    ),
    count > shown.length ? h('p.t-caption', { text: t.plural('card.transactions.more', count - shown.length) }) : null,
  );
}

// ---------------------------------------------------------------- memory, drafts, sources, photos, music

function memoryCard(t, card) {
  const items = list(card.payload.items);
  if (items.length === 0) return genericCard(t, card);
  return cardShell(
    card.title,
    items.slice(0, MAX_ROWS).map((item) =>
      h(
        'div.product',
        null,
        h('p.zoro-body', { text: item.text ?? '' }),
        h(
          'div.product-meta',
          null,
          item.category ? h('span', { text: t.has(`memory.category.${item.category}`) ? t(`memory.category.${item.category}`) : item.category }) : null,
          item.status === 'pending_review' ? badge(t('card.memory.pending'), 'genda') : null,
        ),
      ),
    ),
  );
}

function draftCard(t, card) {
  const draft = card.payload;
  if (typeof draft.text !== 'string') return genericCard(t, card);
  const statusKey = draft.status === 'draft' ? 'card.draft.status.draft' : draft.status === 'sent' ? 'card.draft.status.sent' : null;
  return cardShell(
    card.title,
    facts([
      { label: t('card.draft.to'), value: draft.recipient_display || draft.recipient_address },
      { label: t('card.draft.subject'), value: draft.subject },
      { label: t('card.draft.message'), value: draft.text, stacked: draft.text.length > 60 },
    ]),
    h('p.source-line', { text: statusKey ? t(statusKey) : t('card.draft.status.other', { status: String(draft.status ?? '') }) }),
  );
}

function sourcesCard(t, card) {
  const items = list(card.payload.sources).length ? list(card.payload.sources) : list(card.payload.items);
  if (items.length === 0) return genericCard(t, card);
  return cardShell(
    card.title,
    items.slice(0, MAX_ROWS).map((item) => {
      const url = safeHttpsUrl(item.url);
      const title = item.title || item.name || (url ? new URL(url).hostname : '');
      const excerpt = item.excerpt || item.snippet || item.summary || '';
      return h(
        'div.product',
        null,
        h('p.product-name', { text: `${title}${item.page ? `, p. ${item.page}` : ''}` }),
        excerpt ? h('p.t-detail', { text: String(excerpt).slice(0, 400) }) : null,
        url
          ? h('a.btn.btn--link', { href: url, target: '_blank', rel: 'noopener noreferrer', 'aria-label': `${t('card.sources.open')}: ${new URL(url).hostname}` }, icon('link', { size: 16 }), new URL(url).hostname)
          : null,
      );
    }),
  );
}

function photoCard(t, card) {
  const chips = list(card.payload.chips);
  return cardShell(
    card.title,
    chips.length ? h('div.chips', null, chips.map((chip) => badge(String(chip.label ?? '')))) : null,
    h('p.note', { text: t('card.photos.native') }),
  );
}

function musicCard(t, card) {
  const now = isObject(card.payload.now_playing) ? card.payload.now_playing : null;
  const tracks = list(card.payload.tracks);
  if (!now && tracks.length === 0) return genericCard(t, card);
  const line = (track) => h('div.product', null, h('p.product-name', { text: track.title ?? '' }), h('div.product-meta', null, track.artist ? h('span', { text: track.artist }) : null, track.album ? h('span', { text: track.album }) : null));
  return cardShell(
    now ? t('card.music.now_playing') : card.title,
    now ? line(now) : tracks.slice(0, MAX_ROWS).map(line),
    card.payload.provider ? h('p.source-line', { text: readableSource(card.payload.provider) }) : null,
  );
}

// ---------------------------------------------------------------- generic fallback

function scalarText(t, value) {
  if (value === null || value === undefined) return t('common.not_reported');
  if (typeof value === 'boolean') return t(value ? 'common.yes' : 'common.no');
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) return formatWhen(value, t.lang);
  return String(value);
}

function readableKey(key) {
  const words = String(key).replace(/_/g, ' ');
  return words ? words[0].toUpperCase() + words.slice(1) : '';
}

/** Any card kind the web app has no dedicated view for: its own values, as sent. */
export function genericCard(t, card) {
  const payload = isObject(card.payload) ? card.payload : {};
  const scalars = Object.entries(payload).filter(([, value]) => value === null || ['string', 'number', 'boolean'].includes(typeof value));
  const nested = Object.entries(payload).filter(([, value]) => value !== null && typeof value === 'object');
  const strings = nested.filter(([, value]) => Array.isArray(value) && value.length > 0 && value.every((entry) => typeof entry === 'string'));
  const empty = scalars.length === 0 && nested.length === 0;
  let raw = '';
  try {
    raw = JSON.stringify(payload, null, 2).slice(0, 6000);
  } catch {
    raw = '';
  }
  return cardShell(
    card.title || readableKey(card.kind),
    empty ? h('p.note', { text: t('card.generic.empty') }) : null,
    scalars.length ? facts(scalars.slice(0, 14).map(([key, value]) => ({ label: readableKey(key), value: scalarText(t, value).slice(0, 600) }))) : null,
    strings.map(([key, value]) => h('div.kv', null, h('p.t-detail', { text: readableKey(key) }), h('ul.bullets', null, value.slice(0, 8).map((entry) => h('li', null, icon('check', { size: 16 }), h('span', { text: entry.slice(0, 300) })))))),
    !empty ? h('p.t-caption', { text: t('card.generic.note') }) : null,
    nested.length && raw ? h('details.disclosure', null, h('summary', { text: t('card.generic.more') }), h('pre.mono', { tabindex: '0', text: raw })) : null,
  );
}

const RENDERERS = Object.freeze({
  products: productsCard,
  basket: basketCard,
  basket_comparison: comparisonCard,
  finance_summary: financeCard,
  transactions: transactionsCard,
  memory: memoryCard,
  message_draft: draftCard,
  sources: sourcesCard,
  photo_query: photoCard,
  music: musicCard,
});

/** Kinds with a dedicated view. Every other kind goes through `genericCard`. */
export const CARD_KINDS = Object.freeze(Object.keys(RENDERERS));

/** Render a `UICard`. A renderer that meets a payload it does not understand falls back to the
 * generic view rather than showing an empty or broken card.
 * @param {(key: string, params?: any) => string} t
 * @param {{kind: string, title?: string | null, payload?: any}} card @param {Date} [now] */
export function renderCard(t, card, now = new Date()) {
  const safe = { kind: String(card?.kind ?? 'unknown'), title: card?.title ?? null, payload: isObject(card?.payload) ? card.payload : {} };
  const renderer = RENDERERS[safe.kind] ?? genericCard;
  let node;
  try {
    node = renderer(t, safe, now);
  } catch {
    node = genericCard(t, safe);
  }
  node.dataset.cardKind = safe.kind;
  return node;
}
