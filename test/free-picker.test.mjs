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
