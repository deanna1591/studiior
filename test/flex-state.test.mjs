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
test("reaching the minimum or committing reads 'Running'", () => {
  assert.equal(flexStateChip({ ...base, paid: 2, reachedMinimum: true }).text, "Running");
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
