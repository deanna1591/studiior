import { test } from "node:test";
import assert from "node:assert/strict";
import { isDeleteConfirmed, DELETE_CONSEQUENCES } from "../lib/account-delete.mjs";

test("DELETE (exact) confirms", () => { assert.equal(isDeleteConfirmed("DELETE"), true); });
test("case and surrounding space tolerated", () => {
  assert.equal(isDeleteConfirmed("  delete "), true);
  assert.equal(isDeleteConfirmed("Delete"), true);
});
test("anything else does not confirm", () => {
  assert.equal(isDeleteConfirmed("DELET"), false);
  assert.equal(isDeleteConfirmed("delete my account"), false);
  assert.equal(isDeleteConfirmed(""), false);
  assert.equal(isDeleteConfirmed(null), false);
  assert.equal(isDeleteConfirmed(undefined), false);
});
test("consequences are a non-empty, deletion-is-permanent list", () => {
  assert.ok(Array.isArray(DELETE_CONSEQUENCES) && DELETE_CONSEQUENCES.length >= 4);
  assert.ok(DELETE_CONSEQUENCES.some((c) => /cannot be undone/i.test(c)));
  assert.ok(DELETE_CONSEQUENCES.some((c) => /no automatic refund/i.test(c)));
});
