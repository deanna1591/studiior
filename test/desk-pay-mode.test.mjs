// Decision 73 (c) and 103 (p): the Settings → Booking "Pay at the desk" radio.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DESK_PAY_MODES, normaliseDeskPayMode } from "../lib/desk-pay-mode.mjs";

test("three modes, in order, staff_only last with its help text", () => {
  assert.deepEqual(DESK_PAY_MODES.map((m) => m.value), ["earned", "first_visit_only", "staff_only"]);
  const so = DESK_PAY_MODES.find((m) => m.value === "staff_only");
  assert.equal(so.label, "Staff only");
  assert.equal(so.help, "Staff only. Members pay online. Front desk and up can still mark a booking to pay at the studio.");
  for (const m of DESK_PAY_MODES) assert.ok(!m.help.includes("—"));
});

test("an unknown value saves as earned", () => {
  assert.equal(normaliseDeskPayMode("staff_only"), "staff_only");
  assert.equal(normaliseDeskPayMode("first_visit_only"), "first_visit_only");
  assert.equal(normaliseDeskPayMode("anything"), "earned");
  assert.equal(normaliseDeskPayMode(null), "earned");
});
