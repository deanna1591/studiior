import { test } from "node:test";
import assert from "node:assert/strict";
import { FREE_PICKER_HEADING, freePickerSubline } from "../lib/free-picker.mjs";

test("the heading is 'Book your free class' in both modes", () => {
  assert.equal(FREE_PICKER_HEADING, "Book your free class");
});

test("core-only reads 'These classes always run. Pick one.'", () => {
  assert.equal(freePickerSubline({ coreOnly: true }), "These classes always run. Pick one.");
});

test("the limit off reads 'Pick one.'", () => {
  assert.equal(freePickerSubline({ coreOnly: false }), "Pick one.");
  assert.equal(freePickerSubline({}), "Pick one.");
});

test("the reservation sentence follows when the fee is on", () => {
  assert.equal(
    freePickerSubline({ coreOnly: true, reservationFeeLabel: "₱150" }),
    "These classes always run. Pick one. A ₱150 reservation fee holds your spot and comes off your next purchase when you show up.",
  );
  assert.equal(
    freePickerSubline({ coreOnly: false, reservationFeeLabel: "₱150" }),
    "Pick one. A ₱150 reservation fee holds your spot and comes off your next purchase when you show up.",
  );
});

test("no em dashes on the picker copy", () => {
  for (const s of [
    FREE_PICKER_HEADING,
    freePickerSubline({ coreOnly: true }),
    freePickerSubline({ coreOnly: false }),
    freePickerSubline({ coreOnly: true, reservationFeeLabel: "₱150" }),
  ]) {
    assert.ok(!s.includes("—"), `em dash in: ${s}`);
  }
});

// Decision 30 (f): the picker row uses the class card, one "Book for free"
// button, and the same chip table every member sees.
import { FREE_PICKER_BUTTON, freePickerTier } from "../lib/free-picker.mjs";
import { memberFlexChip } from "../lib/flex-state.mjs";

test("30(f): the picker button reads Book for free, no asterisk", () => {
  assert.equal(FREE_PICKER_BUTTON, "Book for free");
  assert.ok(!FREE_PICKER_BUTTON.includes("*"));
});

test("30(f): a core row reads Always runs; flex rows read the chip table", () => {
  const chip = (row) => {
    const t = freePickerTier(row, { guaranteesEnabled: true });
    if (t.alwaysRuns) return "Always runs";
    return memberFlexChip(t.flexState)?.label ?? null;
  };
  assert.equal(chip({ occ_flex: false }), "Always runs");
  assert.equal(chip({ occ_flex: true, occ_paid_count: 0, occ_min: 2 }), "Needs 2 to run");
  assert.equal(chip({ occ_flex: true, occ_paid_count: 1, occ_min: 2 }), "Needs 1 more to run");
  assert.equal(chip({ occ_flex: true, occ_paid_count: 1, occ_min: 2, occ_reached_minimum: true }), "Confirmed");
});

test("30(f): a core row shows nothing when the studio does not run guarantees", () => {
  const t = freePickerTier({ occ_flex: false }, { guaranteesEnabled: false });
  assert.equal(t.alwaysRuns, false);
  assert.equal(t.flexState, null);
});
