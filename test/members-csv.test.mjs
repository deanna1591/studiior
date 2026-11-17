import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csvCell, membersCsv, exportFilename, MEMBERS_CSV_HEADER } from '../lib/members-csv.mjs';

test('csvCell escapes commas, quotes, newlines; keeps plain', () => {
  assert.equal(csvCell('Ann'), 'Ann');
  assert.equal(csvCell('Smith, Jr'), '"Smith, Jr"');
  assert.equal(csvCell('He said "hi"'), '"He said ""hi"""');
  assert.equal(csvCell('line1\nline2'), '"line1\nline2"');
  assert.equal(csvCell(null), '');
  assert.equal(csvCell(''), '');
});

test('leading zeros and + are preserved as text (no number coercion)', () => {
  assert.equal(csvCell('09170000001'), '09170000001');
  assert.equal(csvCell('+639170000001'), '+639170000001');
  assert.equal(csvCell('0042'), '0042');
});

test('membersCsv has the header and one row per member, CRLF', () => {
  const out = membersCsv([
    { first_name: 'Ann', last_name: 'Lee', email: 'a@x.test', phone: '+639170000001',
      status: 'active', plan: 'Monthly', credits_or_expiry: 'unlimited',
      last_visit: '2026-11-01', joined: '2026-10-01', free_class: 'taken', marketing: 'yes' },
    { first_name: 'Bo', last_name: 'Cruz, Jr', email: 'b@x.test', phone: '09170000002',
      status: 'lead', plan: '', credits_or_expiry: 'expires 2026-12-01',
      last_visit: '', joined: '2026-10-02', free_class: 'none', marketing: 'no' },
  ]);
  const lines = out.replace(/\r\n$/, '').split('\r\n');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], MEMBERS_CSV_HEADER.join(','));
  assert.ok(lines[1].startsWith('Ann,Lee,a@x.test,+639170000001,'));
  assert.ok(lines[2].includes('"Cruz, Jr"'));           // comma quoted
  assert.ok(lines[2].includes('09170000002'));          // leading zero kept
  assert.ok(out.endsWith('\r\n'));
});

test('exportFilename is {slug}-members-{YYYY-MM-DD}.csv', () => {
  assert.equal(exportFilename('reformcollective', new Date(2026, 10, 16)), 'reformcollective-members-2026-11-16.csv');
  assert.equal(exportFilename('Reform Collective', new Date(2026, 0, 5)), 'reform-collective-members-2026-01-05.csv');
  assert.equal(exportFilename('', new Date(2026, 10, 16)), 'studio-members-2026-11-16.csv');
});
