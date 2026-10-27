// Decision 75a — the pure statement helpers (lib/statement.mjs). Zero deps:
//   node --test test/statement.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { isMoneyRow, filterStatement, groupByMonth, withRunningBalance, rowLine, statementTitle } from "../lib/statement.mjs";

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

// Decision 83 (a): statementTitle + rowLine, one per row kind in the table.
const peso = (c) => `₱${(c / 100).toLocaleString("en-US")}`;
const TZ = "Europe/Prague";       // Nov is UTC+1 here
const START = "2026-11-05T06:00:00Z";  // -> 07:00 local, a Thursday
// A class row's when-phrase, so the assertions don't re-derive the weekday.
const WHEN = rowLine({ kind: "attended", occurrence_start: START, instructor_first: "Ada" }, peso, TZ, false);

test("83a classWhen: attended carries the studio-local date, time and instructor", () => {
  assert.ok(WHEN.includes("5 Nov, 07:00"), WHEN);
  assert.ok(WHEN.endsWith("with Ada"), WHEN);
});

test("83a rowLine: booked from a plan names the plan and the balance left", () => {
  const r = { kind: "booked", occurrence_start: START, instructor_first: "Ada", plan_name: "10-Pack", credits_left_after: 7 };
  assert.equal(rowLine(r, peso, TZ, false), `${WHEN} · 1 class from 10-Pack, 7 left`);
});
test("83a rowLine: booked, free first class", () => {
  assert.equal(rowLine({ kind: "free_first", occurrence_start: START, instructor_first: "Ada" }, peso, TZ, false), `${WHEN} · Free first class`);
});
test("83a rowLine: booked, unpaid drop-in shows the amount due at the desk", () => {
  assert.equal(rowLine({ kind: "booked", occurrence_start: START, instructor_first: "Ada", due_cents: 15000 }, peso, TZ, false), `${WHEN} · Drop-in, ₱150 due at the desk`);
});
test("83a rowLine: booked, paid drop-in", () => {
  assert.equal(rowLine({ kind: "booked", occurrence_start: START, instructor_first: "Ada" }, peso, TZ, false), `${WHEN} · Drop-in, paid`);
});
test("83a rowLine: attended is just the when-phrase", () => {
  assert.equal(rowLine({ kind: "attended", occurrence_start: START, instructor_first: "Ada" }, peso, TZ, false), WHEN);
});
test("83a rowLine: no-show from a plan (no instructor), free, nothing owed", () => {
  const base = rowLine({ kind: "attended", occurrence_start: START }, peso, TZ, false); // bare when, no instructor
  assert.ok(base.includes("5 Nov, 07:00") && !base.includes("with"));
  assert.equal(rowLine({ kind: "no_show", occurrence_start: START, plan_name: "5-Pack", credits_left_after: 4 }, peso, TZ, false), `${base} · Class used from 5-Pack, 4 left`);
  assert.equal(rowLine({ kind: "no_show", occurrence_start: START, is_free_first: true }, peso, TZ, false), `${base} · Free class used`);
  assert.equal(rowLine({ kind: "no_show", occurrence_start: START }, peso, TZ, false), `${base} · Nothing owed`);
});
test("83a rowLine: cancelled in time returns the credit / keeps the free class", () => {
  const base = rowLine({ kind: "cancelled", occurrence_start: START }, peso, TZ, false);
  assert.equal(rowLine({ kind: "cancelled", occurrence_start: START, plan_name: "10-Pack", credits_left_after: 9 }, peso, TZ, false), `${base} · Class returned to 10-Pack, 9 left`);
  assert.equal(rowLine({ kind: "cancelled", occurrence_start: START, is_free_first: true }, peso, TZ, false), `${base} · Free class kept`);
});
test("83a rowLine: cancelled late uses the class", () => {
  const base = rowLine({ kind: "late_cancelled", occurrence_start: START }, peso, TZ, false);
  assert.equal(rowLine({ kind: "late_cancelled", occurrence_start: START, plan_name: "10-Pack", credits_left_after: 8 }, peso, TZ, false), `${base} · Class used from 10-Pack, 8 left`);
});
test("83a rowLine: studio cancelled returns the credit", () => {
  const base = rowLine({ kind: "studio_cancelled", occurrence_start: START }, peso, TZ, false);
  assert.equal(rowLine({ kind: "studio_cancelled", occurrence_start: START, plan_name: "10-Pack", credits_left_after: 9 }, peso, TZ, false), `${base} · Class returned to 10-Pack, 9 left`);
});
test("83a rowLine: a moved class shows the new time", () => {
  assert.equal(rowLine({ kind: "rescheduled", occurrence_start: START }, peso, TZ, false), `Now ${rowLine({ kind: "attended", occurrence_start: START }, peso, TZ, false)}`);
});
test("83a rowLine: a plan purchase shows amount, classes, valid-to, method (desk) + recorder for staff", () => {
  const r = { kind: "purchase", membership_id: "m1", amount_cents: 500000, plan_classes: 5, plan_valid_to: "2026-11-05", payment_method: "cash", recorded_by_name: "Olive Owner" };
  assert.equal(rowLine(r, peso, TZ, false), "₱5,000 · 5 classes, valid to 5 Nov 2026 · Cash at the desk");
  assert.equal(rowLine(r, peso, TZ, true), "₱5,000 · 5 classes, valid to 5 Nov 2026 · Cash at the desk · recorded by Olive Owner");
});
test("83a rowLine: an online purchase has no desk method and no recorder", () => {
  assert.equal(rowLine({ kind: "purchase", membership_id: "m1", amount_cents: 500000, plan_classes: 10 }, peso, TZ, true), "₱5,000 · 10 classes");
});
test("83a rowLine: a paid-for drop-in payment", () => {
  assert.equal(rowLine({ kind: "purchase", booking_id: "b1", amount_cents: 15000, payment_method: "gcash" }, peso, TZ, false), "₱150 · GCash at the desk");
});
test("83a rowLine: classes added shows the balance left", () => {
  assert.equal(rowLine({ kind: "credits_added", credit_delta: 2, plan_name: "10-Pack", credits_left_after: 10 }, peso, TZ, false), "10 left");
});
test("83a rowLine: a plan ended counts the unused classes", () => {
  assert.equal(rowLine({ kind: "plan_ended", plan_name: "5-Pack", unused_credits: 2 }, peso, TZ, false), "2 classes unused");
  assert.equal(rowLine({ kind: "plan_ended", plan_name: "5-Pack", unused_credits: 1 }, peso, TZ, false), "1 class unused");
});
test("83a rowLine: joined / instructor_changed / payment_failed say nothing extra", () => {
  assert.equal(rowLine({ kind: "joined" }, peso, TZ, false), null);
  assert.equal(rowLine({ kind: "instructor_changed", occurrence_start: START }, peso, TZ, false), null);
  assert.equal(rowLine({ kind: "payment_failed", amount_cents: 500000 }, peso, TZ, false), null);
});

test("83a statementTitle: reshapes per the table, no em dash", () => {
  assert.equal(statementTitle({ kind: "booked", title: "Booked Reformer" }), "Booked Reformer");
  assert.equal(statementTitle({ kind: "no_show", title: "Did not attend Reformer" }), "Missed Reformer");
  assert.equal(statementTitle({ kind: "rescheduled", title: "Class rescheduled — Reformer" }), "Reformer moved");
  assert.equal(statementTitle({ kind: "late_cancelled", title: "Cancelled late — Reformer" }), "Cancelled late Reformer");
  assert.equal(statementTitle({ kind: "free_first", title: "Booked a free first class — Reformer" }), "Booked Reformer");
  assert.equal(statementTitle({ kind: "plan_ended", title: "Plan ended", plan_name: "5-Pack" }), "5-Pack ended");
  assert.equal(statementTitle({ kind: "credits_added", title: "Credits added", credit_delta: 2, plan_name: "10-Pack" }), "2 classes added to 10-Pack");
  assert.equal(statementTitle({ kind: "purchase", title: "Bought Reformer", booking_id: "b1", membership_id: null }), "Paid for Reformer");
  assert.equal(statementTitle({ kind: "purchase", title: "Bought 10-Pack", membership_id: "m1" }), "Bought 10-Pack");
});

test("83a: no helper output ever contains an em dash", () => {
  const kinds = ["booked", "free_first", "attended", "no_show", "cancelled", "late_cancelled",
    "studio_cancelled", "rescheduled", "purchase", "refund", "credits_added", "credit_adjustment",
    "plan_ended", "joined", "instructor_changed", "payment_failed"];
  const row = (k) => ({
    kind: k, title: "Class rescheduled — Reformer", occurrence_start: START, instructor_first: "Ada",
    plan_name: "10-Pack", credits_left_after: 4, due_cents: 15000, is_free_first: true,
    amount_cents: 500000, plan_classes: 5, plan_valid_to: "2026-11-05", payment_method: "cash",
    recorded_by_name: "Olive Owner", unused_credits: 2, credit_delta: -1,
    booking_id: k === "purchase" ? null : "b1", membership_id: "m1",
  });
  for (const k of kinds) {
    for (const forStaff of [false, true]) {
      const line = rowLine(row(k), peso, TZ, forStaff);
      if (line) assert.ok(!line.includes("—"), `rowLine ${k}: ${line}`);
    }
    assert.ok(!statementTitle(row(k)).includes("—"), `statementTitle ${k}`);
  }
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
