// Formatting rules from docs/design/voice-and-copy.md: Western digits in both languages, rupees
// with Indian grouping, a real minus sign, 12-hour times with the period of day in Hindi.
// Money is never a float here: amounts arrive as decimal strings and are handled as strings.

const MINUS = '−';
const DECIMAL = /^([+-]?)(\d+)(?:\.(\d+))?$/;

/** Split a decimal string into sign, whole part and exactly two fraction digits, rounding half
 * away from zero. Returns null when the text is not a plain decimal number.
 * @param {unknown} value */
export function toPaiseParts(value) {
  const text = typeof value === 'number' && Number.isInteger(value) ? String(value) : value;
  if (typeof text !== 'string') return null;
  const match = DECIMAL.exec(text.trim());
  if (!match) return null;
  let whole = BigInt(match[2]);
  const fraction = (match[3] || '').padEnd(3, '0');
  let paise = BigInt(fraction.slice(0, 2));
  if (fraction.charCodeAt(2) >= 53) {
    paise += 1n; // third digit is 5 or more: round the magnitude up
    if (paise === 100n) {
      paise = 0n;
      whole += 1n;
    }
  }
  const zero = whole === 0n && paise === 0n;
  return { negative: match[1] === '-' && !zero, whole: whole.toString(), paise: paise.toString().padStart(2, '0') };
}

/** Indian digit grouping: the last three digits, then pairs (12,34,567).
 * @param {string} digits */
export function groupIndian(digits) {
  if (digits.length <= 3) return digits;
  const tail = digits.slice(-3);
  const head = digits.slice(0, -3).replace(/\B(?=(\d{2})+(?!\d))/g, ',');
  return `${head},${tail}`;
}

/** `₹1,23,456.50`. Returns null for anything that is not a decimal amount, so a missing value is
 * never shown as zero.
 * @param {unknown} amount decimal string @param {{currency?: string}} [options] */
export function formatMoney(amount, { currency = 'INR' } = {}) {
  const parts = toPaiseParts(amount);
  if (!parts) return null;
  const symbol = currency === 'INR' ? '₹' : `${currency} `;
  return `${parts.negative ? MINUS : ''}${symbol}${groupIndian(parts.whole)}.${parts.paise}`;
}

/** Amount held as integer paise (shopping provider payloads). @param {unknown} paise */
export function formatPaise(paise) {
  if (typeof paise !== 'number' || !Number.isInteger(paise)) return null;
  const negative = paise < 0;
  const digits = String(Math.abs(paise)).padStart(3, '0');
  return formatMoney(`${negative ? '-' : ''}${digits.slice(0, -2)}.${digits.slice(-2)}`);
}

const MONTHS_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTHS_HI = ['जनवरी', 'फ़रवरी', 'मार्च', 'अप्रैल', 'मई', 'जून', 'जुलाई', 'अगस्त', 'सितंबर', 'अक्टूबर', 'नवंबर', 'दिसंबर'];

function asDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/** Period of day used in Hindi times. @param {number} hour 0..23 */
export function hindiPeriod(hour) {
  if (hour >= 4 && hour < 12) return 'सुबह';
  if (hour >= 12 && hour < 16) return 'दोपहर';
  if (hour >= 16 && hour < 20) return 'शाम';
  return 'रात';
}

/** "4:12 pm" / "शाम 4:12" in the device's time zone. */
export function formatTime(value, lang = 'en') {
  const date = asDate(value);
  if (!date) return '';
  const hour = date.getHours();
  const minute = String(date.getMinutes()).padStart(2, '0');
  const hour12 = hour % 12 === 0 ? 12 : hour % 12;
  if (lang === 'hi') return `${hindiPeriod(hour)} ${hour12}:${minute}`;
  return `${hour12}:${minute} ${hour < 12 ? 'am' : 'pm'}`;
}

/** "12 Nov" / "12 नवंबर", with the year when it is not the current one. */
export function formatDate(value, lang = 'en', now = new Date()) {
  const date = asDate(value);
  if (!date) return '';
  const month = (lang === 'hi' ? MONTHS_HI : MONTHS_EN)[date.getMonth()];
  const year = date.getFullYear() === now.getFullYear() ? '' : ` ${date.getFullYear()}`;
  return `${date.getDate()} ${month}${year}`;
}

function dayNumber(date) {
  return Math.floor(new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime() / 86_400_000);
}

/** 'today' | 'yesterday' | 'earlier', by the device's calendar day. */
export function dayBucket(value, now = new Date()) {
  const date = asDate(value);
  if (!date) return 'earlier';
  const diff = dayNumber(now) - dayNumber(date);
  if (diff <= 0) return 'today';
  return diff === 1 ? 'yesterday' : 'earlier';
}

/** Time today, otherwise the date. */
export function formatWhen(value, lang = 'en', now = new Date()) {
  return dayBucket(value, now) === 'today' ? formatTime(value, lang) : formatDate(value, lang, now);
}

/** Seconds left as "1:45" (never negative). @param {number} seconds */
export function formatCountdown(seconds) {
  const left = Math.max(0, Math.floor(seconds));
  return `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

export const STALE_AFTER_MS = 30 * 60 * 1000;

/** True when a price or reading is older than 30 minutes ("Price may have changed."). */
export function isStale(retrievedAt, now = new Date()) {
  const date = asDate(retrievedAt);
  return !date || now.getTime() - date.getTime() > STALE_AFTER_MS;
}

/** Agents are named in Latin script in both languages, as the copy rules ask for names. */
const AGENT_NAMES = Object.freeze({
  supervisor: 'ZORO',
  voice: 'Voice',
  personal_assistant: 'Assistant',
  memory: 'Memory',
  finance: 'Finance',
  investment: 'Investments',
  shopping: 'Shopping',
  product_research: 'Product research',
  vision: 'Photos',
  communication: 'Communications',
  fitness: 'Fitness',
  music: 'Music',
  device_control: 'Device control',
  document: 'Documents',
  browser_research: 'Research',
  automation: 'Automation',
  security: 'Security',
});

/** @param {string} agentId */
export function agentName(agentId) {
  if (AGENT_NAMES[agentId]) return AGENT_NAMES[agentId];
  const words = String(agentId || '').replace(/_/g, ' ').trim();
  return words ? words[0].toUpperCase() + words.slice(1) : 'ZORO';
}

/** "Shopping", "Shopping and Finance", "Shopping, Finance and Music" (and / और).
 * @param {string[]} names @param {string} lang */
export function joinNames(names, lang = 'en') {
  const and = lang === 'hi' ? 'और' : 'and';
  if (names.length <= 1) return names[0] || '';
  return `${names.slice(0, -1).join(', ')} ${and} ${names[names.length - 1]}`;
}

/** A tool id as words for the generic activity row: "finance.spending_summary" -> "Spending summary". */
export function toolLabel(tool) {
  const last = String(tool || '').split('.').slice(1).join(' ') || String(tool || '');
  const words = last.replace(/[_.]/g, ' ').trim();
  return words ? words[0].toUpperCase() + words.slice(1) : '';
}
