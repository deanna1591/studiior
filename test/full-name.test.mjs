import { test } from "node:test";
import assert from "node:assert/strict";
import { fullName } from "../lib/full-name.mjs";

test("fullName joins first and last", () => {
  assert.equal(fullName("Jane", "Doe"), "Jane Doe");
});

test("fullName is the first alone when the last is empty", () => {
  assert.equal(fullName("Madonna", ""), "Madonna");
  assert.equal(fullName("Madonna", null), "Madonna");
  assert.equal(fullName("Madonna", undefined), "Madonna");
  assert.equal(fullName("Madonna", "   "), "Madonna");
});

test("fullName never copies the first into the last", () => {
  // Whatever the inputs, the result is at most "first last", never "first first".
  assert.equal(fullName("Ara", "Ara"), "Ara Ara"); // genuine same-name is kept as given
  assert.equal(fullName("Ara", ""), "Ara"); // the corrected shape reads as one name
});

test("fullName trims", () => {
  assert.equal(fullName("  Jane  ", "  Doe  "), "Jane Doe");
  assert.equal(fullName("", ""), "");
});
