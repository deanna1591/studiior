import { test } from "node:test";
import assert from "node:assert/strict";
import { isNewVersion, isSuppressedPath } from "../lib/version-check.mjs";

test("isNewVersion: a changed id is new, an equal or unknown id is not", () => {
  assert.equal(isNewVersion("a", "b"), true);
  assert.equal(isNewVersion("a", "a"), false);
  assert.equal(isNewVersion("", "b"), false);
  assert.equal(isNewVersion("a", ""), false);
  assert.equal(isNewVersion(null, "b"), false);
  assert.equal(isNewVersion("a", undefined), false);
});

test("isSuppressedPath: checkout and form screens suppress the bar", () => {
  for (const p of [
    "/checkout/abc", "/reserve/abc", "/buy/plan1", "/purchase/xyz",
    "/waiver", "/account/profile", "/group/g1",
  ]) assert.equal(isSuppressedPath(p), true, p);
  for (const p of ["/book", "/", "/account", "/account/plan", "/history", "/instructor/schedule", "/instructor/shifts"])
    assert.equal(isSuppressedPath(p), false, p);
  assert.equal(isSuppressedPath(null), false);
});
