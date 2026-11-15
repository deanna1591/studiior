import { test } from "node:test";
import assert from "node:assert/strict";
import { accentSolid, accentChip } from "../lib/accent-pair.mjs";

test("accentSolid is the accent fill with its measured on-accent text", () => {
  assert.deepEqual(accentSolid(), {
    background: "var(--accent-solid)",
    color: "var(--accent-on-solid)",
  });
  // never a hard-coded white or ink
  assert.notEqual(accentSolid().color, "#fff");
  assert.notEqual(accentSolid().color, "var(--ink)");
});

test("accentChip is the tint with ink text", () => {
  assert.deepEqual(accentChip(), {
    background: "var(--accent-chip)",
    color: "var(--ink)",
  });
});

test("extra props merge without replacing the pair", () => {
  const s = accentSolid({ opacity: 0.5 });
  assert.equal(s.background, "var(--accent-solid)");
  assert.equal(s.color, "var(--accent-on-solid)");
  assert.equal(s.opacity, 0.5);
});
