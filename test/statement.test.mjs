// Decision 75a — the pure statement helpers (lib/statement.mjs). Zero deps:
//   node --test test/statement.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { isMoneyRow, filterStatement, groupByMonth, withRunningBalance } from "../lib/statement.mjs";

// Newest-first, as member_activity returns.
const rows = [
  { at: "2026-03-10T10:00:00Z", kind: "credits_added", credit_delta: 2, amount_cents: null, balance_after: 10 },
  { at: "2026-03-09T10:00:00Z", kind: "late_cancelled", credit_delta: 0, amount_cents: null, balance_after: 8 },
  { at: "2026-03-02T10:00:00Z", kind: "cancelled", credit_delta: 1, amount_cents: null, balance_after: 9 },
  { at: "2026-02-20T10:00:00Z", kind: "booked", credit_delta: -1, amount_cents: null, balance_after: 8 },
  { at: "2026-02-15T10:00:00Z", kind: "purchase", credit_delta: 10, amount_cents: 500000, balance_after: 10 },
  { at: "2026-02-14T10:00:00Z", kind: "attended", credit_delta: 0, amount_cents: null, balance_after: 0 },
];

test("isMoneyRow: non-zero delta OR an amount", () => {
  assert.equal(isMoneyRow({ credit_delta: -1, amount_cents: null }), true);
  assert.equal(isMoneyRow({ credit_delta: 0, amount_cents: 500 }), true);
  assert.equal(isMoneyRow({ credit_delta: 0, amount_cents: null }), false);
});

test("filterStatement credits = exactly rows with a delta or an amount", () => {
  const c = filterStatement(rows, "credits").map((r) => r.kind);
  assert.deepEqual(c, ["credits_added", "cancelled", "booked", "purchase"]);
});

test("filterStatement classes = class-activity kinds", () => {
  const c = filterStatement(rows, "classes").map((r) => r.kind);
  assert.deepEqual(c, ["late_cancelled", "cancelled", "booked", "attended"]);
});

test("filterStatement all = everything, unchanged order", () => {
  assert.equal(filterStatement(rows, "all").length, rows.length);
});

test("groupByMonth preserves newest-first order and groups contiguously", () => {
  const g = groupByMonth(rows, (at) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", month: "long", year: "numeric" }).format(new Date(at)));
  assert.deepEqual(g.map((x) => x.label), ["March 2026", "February 2026"]);
  assert.equal(g[0].items.length, 3);
  assert.equal(g[1].items.length, 3);
});

test("withRunningBalance recomputes balance_after from deltas (oldest first)", () => {
  const b = withRunningBalance(rows);
  // Oldest: attended 0 -> 0; purchase +10 -> 10; booked -1 -> 9; cancelled +1 -> 10;
  // late 0 -> 10; credits_added +2 -> 12. Newest-first mapping:
  const byKind = Object.fromEntries(b.map((r) => [r.kind, r.balance_after]));
  assert.equal(byKind.attended, 0);
  assert.equal(byKind.purchase, 10);
  assert.equal(byKind.booked, 9);
  assert.equal(byKind.cancelled, 10);
  assert.equal(byKind.late_cancelled, 10);
  assert.equal(byKind.credits_added, 12);
});
