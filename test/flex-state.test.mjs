// Decision 22(e): the flex state chip, and Decision 116(a): the slot rule.
import { test } from "node:test";
import assert from "node:assert/strict";
import { flexStateChip, cancellationCauseLabel } from "../lib/flex-state.mjs";
import { replaceAllowed, slotLabel, REPLACES_LABEL, privateReasonSentence } from "../lib/private-sessions.mjs";

const base = { flex: true, status: "scheduled", committed: false, reachedMinimum: false, paid: 0, unpaid: 0, minimum: 2 };

test("a flex class short of its minimum reads '{paid} of {min}'", () => {
  assert.deepEqual(flexStateChip({ ...base, paid: 1 }), { kind: "count", text: "1 of 2" });
});
test("unpaid seats are added: '1 of 2, 1 unpaid'", () => {
  assert.deepEqual(flexStateChip({ ...base, paid: 1, unpaid: 1 }), { kind: "count", text: "1 of 2, 1 unpaid" });
});
test("reaching the minimum or committing reads 'Confirmed' (staff and members say the same)", () => {
  assert.equal(flexStateChip({ ...base, paid: 2, reachedMinimum: true }).text, "Confirmed");
  assert.equal(flexStateChip({ ...base, committed: true }).kind, "running");
});
test("a cut-off cancellation reads 'not running'; another cancellation shows no chip", () => {
  assert.equal(flexStateChip({ ...base, status: "cancelled", cancellationCause: "unmet_minimum" }).text, "not running");
  assert.equal(flexStateChip({ ...base, status: "cancelled", cancellationCause: "replaced_by_private" }).kind, "none");
});
test("a core class shows no flex chip", () => {
  assert.equal(flexStateChip({ ...base, flex: false }).kind, "none");
});
test("the replaced cause has its staff label", () => {
  assert.equal(cancellationCauseLabel("replaced_by_private"), "Replaced by a private session");
  assert.equal(cancellationCauseLabel("studio_fault"), null);
});

test("slot rule: an empty flex class is replaceable at any distance", () => {
  assert.equal(replaceAllowed({ empty: true, tier: "flex", hoursUntilStart: 500, windowHours: 48 }), true);
});
test("slot rule: an empty core class only inside the window", () => {
  assert.equal(replaceAllowed({ empty: true, tier: "core", hoursUntilStart: 47, windowHours: 48 }), true);
  assert.equal(replaceAllowed({ empty: true, tier: "core", hoursUntilStart: 49, windowHours: 48 }), false);
  assert.equal(replaceAllowed({ empty: true, tier: "always", hoursUntilStart: 60, windowHours: 48 }), false);
});
test("slot rule: a class that is not empty, or already targeted, is never replaceable", () => {
  assert.equal(replaceAllowed({ empty: false, tier: "flex", hoursUntilStart: 10 }), false);
  assert.equal(replaceAllowed({ empty: true, targeted: true, tier: "flex", hoursUntilStart: 10 }), false);
});
test("the slot label and the refusal sentence", () => {
  assert.equal(slotLabel("abc"), REPLACES_LABEL);
  assert.equal(REPLACES_LABEL, "Replaces an empty class");
  assert.equal(slotLabel(null), null);
  assert.equal(privateReasonSentence("time_taken"), "That time was just taken. Pick another time.");
});

import { memberFlexChip } from "../lib/flex-state.mjs";

test("22(f): the member chip table", () => {
  const f = (o) => memberFlexChip({ tier: "flex", min: 2, ...o });
  assert.deepEqual(memberFlexChip({ tier: "core", paid: 0, min: 0 }), { label: "Always runs", tone: "core" });
  assert.deepEqual(memberFlexChip({ tier: "always", paid: 0, min: 0 }), { label: "Always runs", tone: "core" });
  assert.deepEqual(f({ paid: 0 }), { label: "Needs 2 to run", tone: "first" });
  assert.deepEqual(memberFlexChip({ tier: "flex", paid: 0, min: 3 }), { label: "Needs 3 to run", tone: "first" });
  assert.deepEqual(f({ paid: 1 }), { label: "Needs 1 more to run", tone: "needs" });
  assert.deepEqual(memberFlexChip({ tier: "flex", paid: 1, min: 4 }), { label: "Needs 3 more to run", tone: "needs" });
  assert.deepEqual(f({ paid: 2 }), { label: "Confirmed", tone: "running" });
  assert.deepEqual(f({ paid: 2, long: true }), { label: "Confirmed to run", tone: "running" });
  assert.deepEqual(f({ paid: 0, reached: true }), { label: "Confirmed", tone: "running" });
  assert.deepEqual(f({ paid: 1, committed: true, long: true }), { label: "Confirmed to run", tone: "running" });
  assert.equal(f({ paid: 1, long: true }).label, "Needs 1 more to run");
  assert.deepEqual(memberFlexChip({ tier: "core", paid: 0, min: 0, long: true }), { label: "Always runs", tone: "core" });
  assert.equal(f({ paid: 1, isPrivate: true }), null);
  assert.equal(f({ paid: 1, hidden: true }), null);
  assert.equal(memberFlexChip({ tier: null, paid: 0, min: 0 }), null);
  for (const p of [0, 1, 2]) assert.ok(!f({ paid: p }).label.includes("—"));
});
