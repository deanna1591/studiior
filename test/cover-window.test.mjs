import { test } from "node:test";
import assert from "node:assert/strict";
import { coverRequestAllowed } from "../lib/cover-window.mjs";

const START = Date.UTC(2026, 9, 10, 7, 0, 0);
test("allowed before the start", () => { assert.equal(coverRequestAllowed(START - 1, START), true); });
test("refused AT the start", () => { assert.equal(coverRequestAllowed(START, START), false); });
test("refused after the start", () => { assert.equal(coverRequestAllowed(START + 60000, START), false); });
test("bad args -> false", () => {
  assert.equal(coverRequestAllowed(null, START), false);
  assert.equal(coverRequestAllowed(START, undefined), false);
});
