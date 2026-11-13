// A link request that arrived over the device channel (a turn on another device chose this
// browser to open something). The owner sees the exact address and decides; an unsupported
// request is refused at once. The result goes back over the channel.

import { openedResult, openLink, planDeviceAction, refusedResult } from '../core/device-actions.js';
import { linkBlock } from './approval.js';
import { createSheet } from './components.js';

/** @param {(key: string, params?: any) => string} t
 * @param {any} action a `DeviceActionRequest`
 * @param {{send: (result: any) => Promise<any>, toast: (message: string) => void,
 *   onError?: (error: any) => void}} io */
export function offerLinkSheet(t, action, { send, toast, onError = () => {} }) {
  const plan = planDeviceAction(action);
  if (plan.kind === 'refuse') {
    send(refusedResult(action, plan.errorCode)).catch(() => {});
    return;
  }
  const { dialog, body } = createSheet('channel-link-title');
  let answered = false;
  const answer = (result) => {
    if (answered) return;
    answered = true;
    send(result).catch(onError);
    if (dialog.open) dialog.close();
  };
  const block = linkBlock(t, plan, {
    text: action.tool === 'device.whatsapp.compose' ? String(action.args?.text ?? '') : '',
    onOpen: () => (openLink(plan.url) ? answer(openedResult(action)) : toast(t('device.link.blocked'))),
    onSkip: () => answer(refusedResult(action, 'user_cancelled')),
  });
  block.querySelector('h3').id = 'channel-link-title';
  body.append(block);
  const wait = new Date(action.expires_at).getTime() - Date.now();
  const expiry = setTimeout(() => answer(refusedResult(action, 'expired')), Number.isFinite(wait) ? Math.max(0, wait) : 60_000);
  dialog.addEventListener('close', () => {
    clearTimeout(expiry);
    answer(refusedResult(action, 'user_cancelled')); // closed without choosing
    dialog.remove();
  });
  document.body.append(dialog);
  dialog.showModal();
}
