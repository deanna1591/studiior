import { test } from "node:test";
import assert from "node:assert/strict";
import { payeeNoticeLine } from "../lib/payee-notice.mjs";

test("payeeNoticeLine: one sentence, nothing after", () => {
  assert.equal(
    payeeNoticeLine("Reform Collective", "DSV Digital Management Corp"),
    "Note: Card and GCash payments for Reform Collective are processed by DSV Digital Management Corp.",
  );
});

test("payeeNoticeLine: a stored trailing period never doubles", () => {
  const line = payeeNoticeLine("Reform Collective", "DSV Digital Management Corp.");
  assert.equal(
    line,
    "Note: Card and GCash payments for Reform Collective are processed by DSV Digital Management Corp.",
  );
  assert.ok(!line.includes(".."));
});

test("payeeNoticeLine: blank / whitespace / null → no line", () => {
  assert.equal(payeeNoticeLine("Reform Collective", null), null);
  assert.equal(payeeNoticeLine("Reform Collective", undefined), null);
  assert.equal(payeeNoticeLine("Reform Collective", ""), null);
  assert.equal(payeeNoticeLine("Reform Collective", "   "), null);
  assert.equal(payeeNoticeLine("Reform Collective", "."), null);
});
