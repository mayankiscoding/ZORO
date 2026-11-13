// Spaces: read-only summaries where the API allows them. Shopping shows the basket and the
// store comparison; Finance shows the spending summary. Every figure is the server's, with its
// source and time; totals are never computed here.

import { basketBody, comparisonBody, financeBody } from '../ui/cards.js';
import { errorView, section, segmented, stateView } from '../ui/components.js';
import { h, onAction, replace } from '../ui/dom.js';
import { icon } from '../ui/icons.js';

export function createSpaces(app) {
  const { t } = app;
  let shown = false;
  let period = 'this_month';
  let comparing = false;
  let compareError = null;
  let comparison = null;

  const shoppingSlot = h('div');
  const financeSlot = h('div');
  const root = h(
    'section.screen',
    { 'aria-label': t('spaces.title') },
    h(
      'div.scroll',
      null,
      h(
        'div.column',
        null,
        h('div.screen-header', null, h('h1.t-title', { text: t('spaces.title') })),
        shoppingSlot,
        financeSlot,
        section(
          t('spaces.other'),
          {},
          h('p.note', { text: t('spaces.other.line') }),
          h('div.btn-row', null, h('a.btn.btn--secondary.btn--small', { href: '#/' }, icon('orb', { size: 18 }), t('spaces.ask'))),
        ),
      ),
    ),
  );

  async function compare() {
    const basket = app.basket.value?.basket;
    if (!basket || comparing) return;
    comparing = true;
    compareError = null;
    renderShopping();
    try {
      const result = await app.client.compareBasket(basket.basket_id);
      comparison = result?.comparison ?? null;
      if (result?.basket) app.basket.set({ basket: result.basket });
      if (!comparison) compareError = { code: 'unexpected' };
    } catch (error) {
      compareError = error;
    } finally {
      comparing = false;
      renderShopping();
    }
  }

  function renderShopping() {
    const resource = app.basket;
    const nodes = [];
    if (resource.status === 'error' && !resource.value) {
      nodes.push(errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, fallbackKey: 'spaces.shopping.error' }));
    } else if (!resource.value) {
      nodes.push(stateView('loading', t('spaces.shopping.loading'), null, { plain: true }));
    } else if (!resource.value.basket || (resource.value.basket.items ?? []).length === 0) {
      nodes.push(stateView('empty', t('spaces.shopping.empty'), null, { plain: true }));
    } else {
      const basket = resource.value.basket;
      const items = basket.items ?? [];
      nodes.push(
        h(
          'article.card',
          null,
          h('div.card-title', null, h('h3.t-heading', { text: basket.name || t('spaces.shopping') }), h('span.t-detail', { text: t.plural('card.basket.items', items.length) })),
          ...basketBody(t, basket, new Date()),
        ),
      );
      if (comparing) nodes.push(stateView('loading', t('spaces.shopping.comparing'), null, { plain: true }));
      if (compareError) nodes.push(errorView(t, compareError, { retry: compare, pair: app.repair, fallbackKey: 'spaces.shopping.compare_error', plain: true }));
      if (comparison && !comparing) {
        nodes.push(h('article.card', null, h('div.card-title', null, h('h3.t-heading', { text: t('card.compare.title') })), ...comparisonBody(t, comparison, new Date())));
        nodes.push(h('p.note', { text: t('spaces.shopping.handoff') }));
      }
      nodes.push(
        h(
          'div.btn-row',
          null,
          onAction(h(`button.btn.btn--small.${comparison ? 'btn--secondary' : 'btn--primary'}`, { type: 'button', text: t(comparison ? 'spaces.shopping.compare_again' : 'spaces.shopping.compare'), disabled: comparing }), compare),
        ),
      );
    }
    replace(shoppingSlot, section(t('spaces.shopping'), {}, ...nodes));
  }

  function renderFinance() {
    const resource = app.finance;
    const nodes = [
      segmented({
        legend: t('spaces.finance.period'),
        name: 'finance-period',
        value: period,
        options: [
          { value: 'this_month', label: t('spaces.finance.this_month') },
          { value: 'last_month', label: t('spaces.finance.last_month') },
        ],
        onChange: (value) => {
          period = value;
          app.financePeriod = value;
          resource.reset();
          resource.refresh();
        },
      }),
    ];
    if (resource.status === 'error' && !resource.value) {
      const denied = resource.error?.status === 403;
      nodes.push(denied ? stateView('error', t('spaces.finance.denied')) : errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, fallbackKey: 'spaces.finance.error' }));
    } else if (!resource.value) {
      nodes.push(stateView('loading', t('spaces.finance.loading'), null, { plain: true }));
    } else {
      const summary = resource.value;
      const label = (t.lang === 'hi' ? summary.period?.label_hi : summary.period?.label_en) || summary.period?.label_en || '';
      const body = summary.transactions === 0 ? null : financeBody(t, summary);
      if (!body) {
        nodes.push(stateView('empty', t('spaces.finance.empty', { period: label || t(`spaces.finance.${period}`) }), null, { plain: true }));
      } else {
        nodes.push(h('article.card', null, h('div.card-title', null, h('h3.t-heading', { text: label }), h('span.t-detail', { text: t('spaces.finance.top') })), ...body));
        nodes.push(h('p.note', { text: t('spaces.finance.readonly') }));
      }
    }
    replace(financeSlot, section(t('spaces.finance'), {}, ...nodes));
  }

  function render() {
    if (!shown) return;
    renderShopping();
    renderFinance();
  }

  const unsubscribe = [app.basket.subscribe(() => shown && renderShopping()), app.finance.subscribe(() => shown && renderFinance())];

  return {
    root,
    title: () => t('spaces.title'),
    show() {
      shown = true;
      render();
      app.basket.refresh();
      app.finance.refresh();
    },
    hide() {
      shown = false;
    },
    destroy() {
      for (const off of unsubscribe) off();
    },
  };
}
