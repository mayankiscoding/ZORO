// The approval sheet and the link block.
//
// The sheet shows exactly what will be signed: ZORO's sentence stands on the rekha, the facts
// hang below it, then the expiry and the two answers. A request that needs the user-presence
// key (Face ID / Touch ID) gets no Approve or Decline button here, only the explanation and the
// option to withdraw the request.

import { canSignApproval } from '../core/identity.js';
import { agentName, formatCountdown, toolLabel } from '../core/format.js';
import { badge, createSheet, facts, riskBadge } from './components.js';
import { h, onAction, setText } from './dom.js';
import { icon } from './icons.js';

const URGENT_SECONDS = 30;

/** Seconds until an ISO time, never negative. */
export function secondsUntil(iso, now = new Date()) {
  const at = new Date(iso).getTime();
  return Number.isNaN(at) ? 0 : Math.max(0, Math.floor((at - now.getTime()) / 1000));
}

/** The facts shown for an approval: the server's detail rows, plus the summary as "Content"
 * when the rows do not already carry it. Pure, for tests.
 * @param {{summary?: string, details?: {label: string, value: string}[]}} approval
 * @param {string} contentLabel */
export function approvalFacts(approval, contentLabel) {
  const details = Array.isArray(approval.details) ? approval.details.filter((row) => row && typeof row.label === 'string') : [];
  const rows = details.map((row) => ({ label: row.label, value: String(row.value ?? ''), stacked: String(row.value ?? '').length > 48 }));
  const summary = String(approval.summary ?? '').trim();
  if (summary && !details.some((row) => String(row.value ?? '').trim() === summary)) {
    rows.unshift({ label: contentLabel, value: summary, stacked: summary.length > 48 });
  }
  return rows;
}

/** The approval block (also used inline on Home for a waiting request).
 * @returns {{node: HTMLElement, stop: () => void}} */
export function approvalBlock(t, approval, { onExpire = () => {}, now = () => new Date() } = {}) {
  const expiry = h('p.approval-expiry', { role: 'timer' }, icon('clock', { size: 16 }), h('span'));
  const expiryText = expiry.lastElementChild;
  let timer = 0;
  let expired = false;
  const tick = () => {
    const left = secondsUntil(approval.expires_at, now());
    if (left <= 0) {
      setText(expiryText, t('approval.expired'));
      expiry.dataset.urgent = 'true';
      if (!expired) {
        expired = true;
        clearInterval(timer);
        onExpire();
      }
      return;
    }
    setText(expiryText, t('approval.expires', { time: formatCountdown(left) }));
    expiry.dataset.urgent = String(left <= URGENT_SECONDS);
  };
  tick();
  if (!expired) timer = setInterval(tick, 1000);

  const node = h(
    'div.approval',
    null,
    h('p.zoro-voice', { text: approval.title ?? '' }),
    h('div.rekha', { 'aria-hidden': 'true' }),
    facts(approvalFacts(approval, t('approval.content'))),
    approval.tainted ? h('p.callout.callout--genda', { role: 'note' }, icon('alert', { size: 18 }), h('span', { text: t('approval.tainted') })) : null,
    expiry,
    h(
      'details.disclosure',
      null,
      h('summary', { text: t('approval.technical') }),
      facts([
        { label: t('approval.tool'), value: approval.tool, mono: true },
        { label: t('approval.digest'), value: approval.action_digest, mono: true, stacked: true },
      ]),
      h('p.field-hint', { text: t('approval.signing_note') }),
    ),
  );
  return { node, stop: () => clearInterval(timer), isExpired: () => expired };
}

/** Open the approval sheet. Resolves with what the owner chose:
 * 'approve' | 'decline' | 'cancel_request' | 'later'.
 * @param {(key: string, params?: any) => string} t
 * @param {any} approval an `ApprovalRequest`
 * @returns {Promise<string>} */
export function openApprovalSheet(t, approval) {
  return new Promise((resolve) => {
    const { dialog, body } = createSheet('approval-heading');
    const signable = canSignApproval(approval);
    const approve = h('button.btn.btn--block.btn--primary', { type: 'button', text: t('approval.approve') });
    const decline = h('button.btn.btn--block.btn--danger', { type: 'button', text: t('approval.decline') });
    const block = approvalBlock(t, approval, {
      onExpire: () => {
        approve.disabled = true;
        decline.disabled = true;
      },
    });
    if (block.isExpired()) {
      approve.disabled = true;
      decline.disabled = true;
    }
    approve.addEventListener('click', () => dialog.close('approve'));
    decline.addEventListener('click', () => dialog.close('decline'));

    body.append(
      h(
        'div.sheet-head',
        null,
        h(
          'div',
          null,
          h('h2#approval-heading.t-heading', { text: signable ? t('approval.heading') : t('approval.biometric.title') }),
          approval.agent ? h('p.t-detail', { text: t('approval.asked_by', { agent: agentName(approval.agent) }) }) : h('p.t-detail', { text: toolLabel(approval.tool) }),
        ),
        riskBadge(t, approval.risk),
      ),
      block.node,
    );
    if (signable) {
      body.append(
        h('div.btn-stack', null, approve, decline, h('button.btn.btn--block.btn--link', { type: 'button', text: t('approval.later'), autofocus: true, on: { click: () => dialog.close('later') } })),
      );
    } else {
      body.append(
        h('p.callout.callout--moon', { role: 'note' }, icon('lock', { size: 18 }), h('span', { text: t('approval.biometric.body') })),
        h(
          'div.btn-stack',
          null,
          h('button.btn.btn--block.btn--secondary', { type: 'button', text: t('common.close'), autofocus: true, on: { click: () => dialog.close('later') } }),
          approval.turn_id ? h('button.btn.btn--block.btn--danger', { type: 'button', text: t('approval.biometric.cancel'), on: { click: () => dialog.close('cancel_request') } }) : null,
        ),
      );
    }
    dialog.addEventListener('close', () => {
      block.stop();
      const choice = ['approve', 'decline', 'cancel_request'].includes(dialog.returnValue) ? dialog.returnValue : 'later';
      dialog.remove();
      resolve(choice);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

/** A waiting approval as a compact card with one action: open the sheet. */
export function approvalCard(t, approval, onReview) {
  return h(
    'article.card',
    { dataset: { approval: approval.approval_id } },
    h('div.card-title', null, h('h3.t-heading', { text: approval.title ?? toolLabel(approval.tool) }), riskBadge(t, approval.risk)),
    h(
      'div.product-meta',
      null,
      approval.agent ? h('span', { text: agentName(approval.agent) }) : null,
      badge(t(canSignApproval(approval) ? 'agent.status.needs_owner' : 'approval.biometric.title'), canSignApproval(approval) ? 'genda' : 'moon'),
    ),
    h('div.btn-row', null, onAction(h('button.btn.btn--secondary.btn--small', { type: 'button', text: t('approval.review') }), onReview)),
  );
}

/** The link block: the exact address, then Open / Don't open. Nothing opens without a tap.
 * @param {(key: string, params?: any) => string} t
 * @param {{url: string, host: string, tool: string}} plan from `planDeviceAction`
 * @param {{text?: string, onOpen: () => any, onSkip: () => any}} handlers */
export function linkBlock(t, plan, { text, onOpen, onSkip }) {
  const whatsapp = plan.tool === 'device.whatsapp.compose';
  return h(
    'article.card',
    { dataset: { deviceAction: plan.tool } },
    h('div.card-title', null, h('h3.t-heading', { text: t(whatsapp ? 'device.link.whatsapp' : 'device.link.title') })),
    whatsapp && text ? h('p.zoro-body', { text }) : null,
    h('p.link-box', null, h('span.link-host', { text: plan.host }), h('br'), h('span', { text: plan.url })),
    h('p.field-hint', { text: t('device.link.note') }),
    h(
      'div.btn-row',
      null,
      onAction(h('button.btn.btn--primary.btn--small', { type: 'button' }, icon('link', { size: 18 }), t(whatsapp ? 'device.link.open_whatsapp' : 'device.link.open')), onOpen),
      onAction(h('button.btn.btn--secondary.btn--small', { type: 'button', text: t('device.link.skip') }), onSkip),
    ),
  );
}
