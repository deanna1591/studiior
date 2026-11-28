// Decision 24 (a) and 103 (p): the Sold out chip and the offline buy line.
import { test } from "node:test";
import assert from "node:assert/strict";
import { SOLD_OUT_CHIP, SOLD_OUT_SENTENCE, isSoldOut, soldLine, offlineBuyLine } from "../lib/plan-sold.mjs";
import { flexAfterCutoffLine } from "../lib/flex-copy.mjs";

test("the chip and sentence", () => {
  assert.equal(SOLD_OUT_CHIP, "Sold out");
  assert.equal(SOLD_OUT_SENTENCE, "This plan is sold out.");
});

test("isSoldOut reads the state", () => {
  assert.equal(isSoldOut({ max_sold: 20, sold: 20, sold_out: true }), true);
  assert.equal(isSoldOut({ max_sold: 20, sold: 1, sold_out: false }), false);
  assert.equal(isSoldOut(null), false);
});

test("staff see how many are sold", () => {
  assert.equal(soldLine({ max_sold: 20, sold: 1, sold_out: false }), "1 of 20 sold");
  assert.equal(soldLine({ max_sold: null, sold: null, sold_out: false }), null);
});

test("the offline buy line under staff_only", () => {
  assert.equal(offlineBuyLine(true), "Online payment isn’t set up yet. Message the studio to buy.");
  assert.equal(offlineBuyLine(false), "Online payment isn’t set up yet. Pay at the studio.");
});

test("the flex-after-cut-off warning, no em dash", () => {
  const s = flexAfterCutoffLine(0, "₱0");
  assert.equal(s, "This class has 0 booked and its cut-off has passed. Switching to Flex cancels it now and pays the coach ₱0.");
  assert.ok(!s.includes("—"));
});
