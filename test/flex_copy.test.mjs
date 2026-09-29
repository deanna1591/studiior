// Standalone-flex warning copy — say it only when the studio pays standby, and
// name the amount. Runs with zero deps:  node --test test/flex_copy.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { standaloneFlexSentence } from "../lib/flex-copy.mjs";

test("no standby pay (0 -> null) says nothing about a standby fee", () => {
  assert.equal(standaloneFlexSentence(null, 1), "");
  assert.equal(standaloneFlexSentence(null, 5), "");
  assert.equal(standaloneFlexSentence("", 1), "");
  assert.equal(standaloneFlexSentence(undefined, 1), "");
});

test("with standby pay it names the formatted amount (one-off, singular)", () => {
  const s = standaloneFlexSentence("₱400.00", 1);
  assert.match(s, /standalone flex class/);
  assert.match(s, /so it carries the ₱400\.00 standby fee\./);
  assert.doesNotMatch(s, /each carries/);
});

test("with standby pay and several standalone classes it is plural and named", () => {
  const s = standaloneFlexSentence("PHP 400.00", 3);
  assert.match(s, /3 of them are standalone flex classes/);
  assert.match(s, /so each carries the PHP 400\.00 standby fee\./);
});

test("never contains the bare unconditional 'carries a standby fee'", () => {
  // The old false claim. With standby > 0 it is always 'the <amount> standby fee'.
  assert.doesNotMatch(standaloneFlexSentence("₱400.00", 1), /carries a standby fee/);
  assert.doesNotMatch(standaloneFlexSentence("₱400.00", 2), /carry a standby fee/);
});
