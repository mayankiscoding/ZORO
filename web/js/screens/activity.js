// Activity: who is working now, what waits for the owner, and the conversation history.

import { agentName, dayBucket, formatWhen, toolLabel } from '../core/format.js';
import { activityRows, isActive } from '../core/turn-reducer.js';
import { approvalCard } from '../ui/approval.js';
import { confirmDialog, errorView, section, stateView, statusBadge } from '../ui/components.js';
import { h, onAction, replace } from '../ui/dom.js';
import { icon } from '../ui/icons.js';

const AGENT_ICON = { shopping: 'basket', finance: 'rupee', investment: 'rupee', memory: 'memory', communication: 'message', security: 'shield', device_control: 'phone' };

export function createActivity(app) {
  const { t, conversation } = app;
  let shown = false;
  let filter = 'all';
  const nowSlot = h('div');
  const historySlot = h('div');
  const filters = h('div.chips', { role: 'group', 'aria-label': t('activity.filter.label') });
  const root = h(
    'section.screen',
    { 'aria-label': t('activity.title') },
    h('div.scroll', null, h('div.column', null, h('div.screen-header', null, h('h1.t-title', { text: t('activity.title') })), filters, nowSlot, historySlot)),
  );

  function agentRow(row) {
    const detail = row.summary || (row.tool ? toolLabel(row.tool) : toolLabel(row.task)) || '';
    return h(
      'li.row',
      null,
      h('span.row-icon', { 'aria-hidden': 'true' }, icon(AGENT_ICON[row.agent] ?? 'orb', { size: 18 })),
      h('div.row-main', null, h('p.row-title', { text: agentName(row.agent) }), detail ? h('p.row-detail', { text: detail }) : null),
      h('div.row-aside', null, statusBadge(t, row.status)),
    );
  }

  function renderFilters() {
    replace(
      filters,
      ['all', 'working', 'needs_you'].map((key) =>
        h('button.chip', { type: 'button', 'aria-pressed': String(filter === key), text: t(`activity.filter.${key}`), on: { click: () => { filter = key; render(); } } }),
      ),
    );
  }

  function renderNow() {
    const { turn, last } = conversation.state;
    const live = isActive(turn) || turn.phase === 'suspended';
    let rows = live ? activityRows(turn) : [];
    if (filter === 'working') rows = rows.filter((row) => row.status === 'working');
    if (filter === 'needs_you') rows = rows.filter((row) => row.status === 'needs_owner');
    const pending = filter === 'working' ? [] : app.pending.value ?? [];
    const nodes = [];

    if (rows.length > 0) nodes.push(h('ul.rows', null, rows.map(agentRow)));
    if (pending.length > 0) nodes.push(h('div', null, pending.map((approval) => approvalCard(t, approval, () => app.reviewApproval(approval)))));
    if (app.pending.status === 'error' && filter !== 'working') {
      nodes.push(errorView(t, app.pending.error, { retry: () => app.pending.refresh(), pair: app.repair, plain: true }));
    }
    if (nodes.length === 0) {
      nodes.push(stateView('empty', t(filter === 'needs_you' ? 'activity.needs_empty' : 'activity.empty'), null, { plain: true }));
    }
    const out = [section(t('activity.now'), {}, ...nodes)];
    if (!live && last && last.rows.length > 0 && filter === 'all') {
      const engine = last.route?.engine;
      out.push(
        section(
          t('activity.last'),
          { detail: formatWhen(last.at, t.lang) },
          h('ul.rows', null, last.rows.map(agentRow)),
          engine && t.has(`route.engine.${engine}`) ? h('p.source-line', { text: t(`route.engine.${engine}`) }) : null,
        ),
      );
    }
    replace(nowSlot, out);
  }

  function conversationRow(item) {
    const current = item.id === conversation.state.conversationId;
    const open = h(
      'button.row',
      { type: 'button', 'aria-label': `${t('activity.history.open')}: ${item.title}` },
      h(
        'div.row-main',
        null,
        h('p.row-title', { text: item.title || t('activity.history.open') }),
        item.last_message_preview ? h('p.row-detail', { text: item.last_message_preview }) : null,
        h('p.row-detail', { text: `${formatWhen(item.updated_at, t.lang)}, ${t.plural('activity.history.messages', item.message_count ?? 0)}${current ? `, ${t('activity.history.current')}` : ''}` }),
      ),
      h('span.row-aside', { 'aria-hidden': 'true' }, icon('chevron', { size: 18 })),
    );
    onAction(open, async () => {
      await conversation.open(item.id);
      app.navigate('');
    });
    const remove = h('button.icon-btn.icon-btn--quiet', { type: 'button', 'aria-label': `${t('activity.history.delete')}: ${item.title}` }, icon('trash', { size: 20 }));
    onAction(remove, async () => {
      if (!(await confirmDialog(t, { message: t('activity.history.delete_confirm'), confirmLabel: t('common.delete') }))) return;
      try {
        await app.client.deleteConversation(item.id);
        if (current) await conversation.forgetLocal();
        app.conversations.set({ ...app.conversations.value, items: app.conversations.value.items.filter((other) => other.id !== item.id) });
        app.toast(t('activity.history.deleted'));
      } catch (error) {
        app.toastError(error);
      }
    });
    return h('li.row', { class: 'row--split' }, open, remove);
  }

  function renderHistory() {
    const resource = app.conversations;
    let body;
    if (resource.status === 'error' && !resource.value) {
      body = errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, fallbackKey: 'activity.history.error' });
    } else if (!resource.value) {
      body = stateView('loading', t('activity.history.loading'), null, { plain: true });
    } else if (resource.value.items.length === 0) {
      body = stateView('empty', t('activity.history.empty'), null, { plain: true });
    } else {
      const groups = { today: [], yesterday: [], earlier: [] };
      for (const item of resource.value.items) groups[dayBucket(item.updated_at)].push(item);
      body = h(
        'div',
        null,
        ['today', 'yesterday', 'earlier']
          .filter((bucket) => groups[bucket].length > 0)
          .map((bucket) => h('div.section', null, h('p.t-detail', { text: t(`common.${bucket}`) }), h('ul.rows', null, groups[bucket].map(conversationRow)))),
        resource.value.next_cursor
          ? h('div.btn-row', null, onAction(h('button.btn.btn--link', { type: 'button', text: t('common.load_more') }), () => app.loadMoreConversations()))
          : null,
        resource.status === 'error' ? errorView(t, resource.error, { retry: () => resource.refresh(), pair: app.repair, plain: true }) : null,
      );
    }
    replace(historySlot, section(t('activity.history'), {}, body));
  }

  function render() {
    if (!shown) return;
    renderFilters();
    renderNow();
    if (filter === 'all') renderHistory();
    else replace(historySlot);
  }

  const unsubscribe = [conversation.subscribe(render), app.pending.subscribe(render), app.conversations.subscribe(render)];

  return {
    root,
    title: () => t('activity.title'),
    show() {
      shown = true;
      render();
      app.pending.refresh();
      app.conversations.refresh();
    },
    hide() {
      shown = false;
    },
    destroy() {
      for (const off of unsubscribe) off();
    },
  };
}
