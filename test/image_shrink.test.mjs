// Decision 60 — the pure box maths behind shrinkToSquare (lib/image-shrink.mjs).
// The canvas work needs a browser, but the centred-square crop + cap is pure
// and is the part most easily got wrong. Runs with zero deps:
//   node --test test/image_shrink.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { squareCrop } from "../lib/image-shrink.mjs";

test("a landscape image keeps its full height and loses the sides", () => {
  // 1600×600, max 800: side = 600, centred horizontally, not upscaled past 600.
  assert.deepEqual(squareCrop(1600, 600, 800), { sx: 500, sy: 0, side: 600, target: 600 });
});

test("a portrait image keeps its full width and loses top/bottom", () => {
  assert.deepEqual(squareCrop(600, 1600, 800), { sx: 0, sy: 500, side: 600, target: 600 });
});

test("a large square is capped at max", () => {
  assert.deepEqual(squareCrop(1000, 1000, 800), { sx: 0, sy: 0, side: 1000, target: 800 });
});

test("a small square is never upscaled", () => {
  assert.deepEqual(squareCrop(300, 300, 800), { sx: 0, sy: 0, side: 300, target: 300 });
});

test("an odd offset rounds, and target never exceeds the shorter side", () => {
  // 1001×1000: side 1000, sx round(0.5)=1; target min(1000,800)=800.
  assert.deepEqual(squareCrop(1001, 1000, 800), { sx: 1, sy: 0, side: 1000, target: 800 });
});
