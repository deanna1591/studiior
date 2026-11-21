import { test } from "node:test";
import assert from "node:assert/strict";
import { reservationChip, freeSeatsLine } from "../lib/reservation-chip.mjs";

const money = (c, cur) => `${cur === "PHP" ? "₱" : cur}${(c / 100).toLocaleString("en-US")}`;

test("the five states word themselves", () => {
  assert.deepEqual(reservationChip({ state: "paid", feeCents: 50000, currency: "PHP" }, money), { text: "Paid ₱500", tone: "ok" });
  assert.deepEqual(reservationChip({ state: "covered" }, money), { text: "Credit covers", tone: "ok" });
  assert.deepEqual(reservationChip({ state: "waived" }, money), { text: "Fee waived", tone: "muted" });
  assert.deepEqual(reservationChip({ state: "due", deadlineLabel: "8:00 PM Sat 21 Nov" }, money), { text: "Due by 8:00 PM Sat 21 Nov", tone: "warn" });
  assert.deepEqual(reservationChip({ state: "not_asked" }, money), { text: "Not asked", tone: "warn" });
});

test("no state, no chip", () => {
  assert.equal(reservationChip({ state: null }, money), null);
  assert.equal(reservationChip(null, money), null);
  assert.equal(reservationChip({ state: "something_else" }, money), null);
});

test("the Flex pending line", () => {
  assert.equal(freeSeatsLine({ n: 3, paid: 1, due: 1, waived: 1 }), "3 free seats: 1 paid, 1 due, 1 waived");
  assert.equal(freeSeatsLine({ n: 1, paid: 0, due: 1, waived: 0 }), "1 free seat: 0 paid, 1 due, 0 waived");
  assert.equal(freeSeatsLine({ n: 0, paid: 0, due: 0, waived: 0 }), null);
});

test("no em dash in any chip or line", () => {
  for (const st of ["paid", "covered", "waived", "due", "not_asked"]) {
    assert.ok(!reservationChip({ state: st, feeCents: 1, currency: "PHP", deadlineLabel: "x" }, money).text.includes("—"));
  }
  assert.ok(!freeSeatsLine({ n: 2, paid: 1, due: 1, waived: 0 }).includes("—"));
});
