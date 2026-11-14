import { test } from "node:test";
import assert from "node:assert/strict";
import { creditOnCheckout, creditLines, netTotalCents, CREDIT_FLOOR_CENTS } from "../lib/reservation-credit.mjs";

const peso = (c) => `₱${(c / 100).toFixed(0)}`;

test("credit applies up to price minus the floor; remainder stays", () => {
  // credit 15000, price 14000 -> applied = 14000-2000 = 12000, remaining 3000
  assert.deepEqual(creditOnCheckout(15000, 14000), { applied: 12000, remaining: 3000 });
});

test("credit smaller than the headroom is fully applied", () => {
  // credit 1500, price 14000 -> headroom 12000, applied 1500, remaining 0
  assert.deepEqual(creditOnCheckout(1500, 14000), { applied: 1500, remaining: 0 });
});

test("a tiny purchase leaves the whole credit (headroom 0)", () => {
  // price 2000 -> headroom max(0,0)=0, nothing applied
  assert.deepEqual(creditOnCheckout(15000, 2000), { applied: 0, remaining: 15000 });
  assert.deepEqual(creditOnCheckout(15000, 1500), { applied: 0, remaining: 15000 });
});

test("no credit -> nothing applied", () => {
  assert.deepEqual(creditOnCheckout(0, 14000), { applied: 0, remaining: 0 });
  assert.equal(CREDIT_FLOOR_CENTS, 2000);
});

test("lines: applied only (no remainder)", () => {
  const { applied, remaining } = creditOnCheckout(1500, 14000);
  assert.deepEqual(creditLines(applied, remaining, peso), ["₱15 reservation credit applied."]);
});

test("lines: applied + remainder", () => {
  const { applied, remaining } = creditOnCheckout(15000, 14000);
  assert.deepEqual(creditLines(applied, remaining, peso), [
    "₱120 reservation credit applied.",
    "₱30 stays on your account.",
  ]);
});

test("lines: nothing applied -> no lines", () => {
  const { applied, remaining } = creditOnCheckout(15000, 2000);
  assert.deepEqual(creditLines(applied, remaining, peso), []);
});

test("netTotalCents: Decision 103 note — the Total is the net after the credit", () => {
  // Credit fully applies: price 14000, credit 5000, floor 2000 -> applied 5000.
  assert.equal(netTotalCents(5000, 14000), 9000);
  // Capped by the floor: price 15000, credit 15000 -> applied 13000, net = floor.
  assert.equal(netTotalCents(15000, 15000), CREDIT_FLOOR_CENTS);
  // Net never drops below the floor.
  assert.ok(netTotalCents(999999, 15000) >= CREDIT_FLOOR_CENTS);
  // No credit -> net is the gross price.
  assert.equal(netTotalCents(0, 14000), 14000);
  // Price at or below the floor -> nothing applies, net is the price.
  assert.equal(netTotalCents(15000, 2000), 2000);
});
