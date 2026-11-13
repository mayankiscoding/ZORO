// Small DOM helpers. Text from the server, the owner or a tool is only ever set as text
// (`textContent`), never parsed as markup: there is no `innerHTML` in this app, and the
// Content-Security-Policy forbids inline script and style on top of that.

const SVG_NS = 'http://www.w3.org/2000/svg';

/** Create an element.
 * @param {string} tag tag name with optional id and classes: 'button#send.btn.btn--primary'
 * @param {Record<string, any> | null} [props] attributes; `text`, `on`, `dataset`, `hidden` are special
 * @param {...(Node | string | null | undefined | false | (Node | string | null | undefined | false)[])} children */
export function h(tag, props, ...children) {
  const [head, ...classes] = tag.split('.');
  const [name, id] = head.split('#');
  const element = document.createElement(name || 'div');
  if (id) element.id = id;
  if (classes.length) element.className = classes.join(' ');
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === 'text') element.textContent = String(value);
      else if (key === 'class') element.className = `${element.className} ${value}`.trim();
      else if (key === 'on') {
        for (const [event, handler] of Object.entries(value)) element.addEventListener(event, handler);
      } else if (key === 'dataset') {
        for (const [dataKey, dataValue] of Object.entries(value)) element.dataset[dataKey] = String(dataValue);
      } else if (key === 'hidden') element.hidden = Boolean(value);
      else if (value === true) element.setAttribute(key, '');
      else element.setAttribute(key, String(value));
    }
  }
  append(element, children);
  return element;
}

/** @param {Element} parent @param {any[]} children */
export function append(parent, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return parent;
}

/** Replace an element's children. */
export function replace(parent, ...children) {
  parent.replaceChildren();
  return append(parent, children);
}

/** Set text only when it changed, so live regions and layout are not disturbed for nothing. */
export function setText(element, text) {
  const next = String(text ?? '');
  if (element.textContent !== next) element.textContent = next;
}

/** An inline SVG icon from path data (decorative: hidden from assistive technology).
 * @param {string[]} paths @param {{size?: number, fill?: boolean}} [options] */
export function svgIcon(paths, { size = 24, fill = false } = {}) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.classList.add('icon');
  for (const data of paths) {
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', data);
    if (fill) {
      path.setAttribute('fill', 'currentColor');
    } else {
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', 'currentColor');
      path.setAttribute('stroke-width', '1.8');
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
    }
    svg.append(path);
  }
  return svg;
}

/** Run `handler` on click, guarding against double activation while a promise is pending. */
export function onAction(element, handler) {
  let running = false;
  element.addEventListener('click', async (event) => {
    if (running) return;
    running = true;
    element.setAttribute('aria-busy', 'true');
    try {
      await handler(event);
    } finally {
      running = false;
      element.removeAttribute('aria-busy');
    }
  });
  return element;
}

/** Keep a list's DOM in step with data by key, reusing nodes so nothing flashes or jumps.
 * @param {Element} parent
 * @param {any[]} items
 * @param {(item: any) => string} keyOf
 * @param {(item: any) => Element} create
 * @param {(node: Element, item: any) => void} [update] */
export function reconcile(parent, items, keyOf, create, update = () => {}) {
  const existing = new Map();
  for (const child of [...parent.children]) {
    if (child.dataset.key !== undefined) existing.set(child.dataset.key, child);
  }
  let previous = null;
  for (const item of items) {
    const key = keyOf(item);
    let node = existing.get(key);
    if (node) {
      existing.delete(key);
      update(node, item);
    } else {
      node = create(item);
      node.dataset.key = key;
    }
    const expected = previous ? previous.nextElementSibling : parent.firstElementChild;
    if (expected !== node) parent.insertBefore(node, expected);
    previous = node;
  }
  for (const node of existing.values()) node.remove();
}
