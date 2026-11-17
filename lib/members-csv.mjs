/**
 * Decision 109: the members export CSV, built client-side from members_export's
 * rows. Phone and dates are already text from the RPC; we keep them text so a
 * spreadsheet does not reformat a +63 number or strip a leading zero from a
 * date. RFC 4180 escaping: a cell with a comma, a quote or a newline is wrapped
 * in double quotes and its own quotes are doubled.
 */
export const MEMBERS_CSV_HEADER = [
  'First name', 'Last name', 'Email', 'Phone', 'Status', 'Plan',
  'Credits left or expiry', 'Last visit', 'Joined', 'Free class', 'Marketing',
];

const FIELDS = [
  'first_name', 'last_name', 'email', 'phone', 'status', 'plan',
  'credits_or_expiry', 'last_visit', 'joined', 'free_class', 'marketing',
];

/** One CSV cell, RFC 4180 escaped. null/undefined become empty. */
export function csvCell(v) {
  const s = v == null ? '' : String(v);
  if (s === '') return '';
  if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

function csvRow(cells) {
  return cells.map(csvCell).join(',');
}

/** The whole file: header row then one row per member, in the order given. */
export function membersCsv(rows) {
  const lines = [csvRow(MEMBERS_CSV_HEADER)];
  for (const r of rows || []) lines.push(csvRow(FIELDS.map((f) => r[f])));
  // CRLF line endings, the spreadsheet-safe default.
  return lines.join('\r\n') + '\r\n';
}

/** {slug}-members-{YYYY-MM-DD}.csv — slug lower-cased, non-word chars to '-'. */
export function exportFilename(slug, date) {
  const d = (date instanceof Date ? date : new Date(date || Date.now()));
  const ymd = [d.getFullYear(), d.getMonth() + 1, d.getDate()]
    .map((n, i) => (i === 0 ? String(n) : String(n).padStart(2, '0'))).join('-');
  const safe = String(slug || 'studio').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'studio';
  return `${safe}-members-${ymd}.csv`;
}
