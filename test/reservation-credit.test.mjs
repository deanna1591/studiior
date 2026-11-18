import { test } from "node:test";
import assert from "node:assert/strict";
import { creditOnCheckout, creditLines, netTotalCents, CREDIT_FLOOR_CENTS } from "../lib/reservation-credit.mjs";

const peso = (c) => `₱${(c / 100).toFixed(0)}`;

test("partial credit applies up to price minus the floor; remainder stays", () => {
  // credit 1500 < price 14000 -> headroom 12000, applied 1500, remaining 0
  assert.deepEqual(creditOnCheckout(1500, 14000), { applied: 1500, remaining: 0, fullyCovered: false });
  // credit 5000 < price 14000 -> applied 5000, remaining 0
  assert.deepEqual(creditOnCheckout(5000, 14000), { applied: 5000, remaining: 0, fullyCovered: false });
});

test("Decision 103(f): credit >= price fully covers — no floor, remainder stays", () => {
  // credit 15000 >= price 14000 -> applied 14000 (whole), remaining 1000, covered
  assert.deepEqual(creditOnCheckout(15000, 14000), { applied: 14000, remaining: 1000, fullyCovered: true });
  // exact cover: nothing remains
  assert.deepEqual(creditOnCheckout(15000, 15000), { applied: 15000, remaining: 0, fullyCovered: true });
  // a tiny total fully covered (below the floor) — the floor only matters when Xendit runs
  assert.deepEqual(creditOnCheckout(15000, 2000), { applied: 2000, remaining: 13000, fullyCovered: true });
  assert.deepEqual(creditOnCheckout(15000, 1500), { applied: 1500, remaining: 13500, fullyCovered: true });
});

test("no credit -> nothing applied", () => {
  assert.deepEqual(creditOnCheckout(0, 14000), { applied: 0, remaining: 0, fullyCovered: false });
  assert.equal(CREDIT_FLOOR_CENTS, 2000);
});

test("lines: applied only (no remainder)", () => {
  const { applied, remaining } = creditOnCheckout(1500, 14000);
  assert.deepEqual(creditLines(applied, remaining, peso), ["₱15 reservation credit applied."]);
});

test("lines: applied + remainder (full cover with leftover)", () => {
  const { applied, remaining } = creditOnCheckout(15000, 14000);
  assert.deepEqual(creditLines(applied, remaining, peso), [
    "₱140 reservation credit applied.",
    "₱10 stays on your account.",
  ]);
});

test("netTotalCents", () => {
  // Partial: price 14000, credit 5000 -> applied 5000, net 9000.
  assert.equal(netTotalCents(5000, 14000), 9000);
  // Decision 103(f): full cover -> net 0.
  assert.equal(netTotalCents(15000, 15000), 0);
  assert.equal(netTotalCents(999999, 15000), 0);
  // No credit -> net is the gross price.
  assert.equal(netTotalCents(0, 14000), 14000);
  // A tiny total fully covered -> net 0.
  assert.equal(netTotalCents(15000, 2000), 0);
});
