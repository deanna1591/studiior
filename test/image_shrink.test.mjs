// Decision 60 — the pure box maths behind shrinkToSquare (lib/image-shrink.mjs).
// The canvas work needs a browser, but the centred-square crop + cap is pure
// and is the part most easily got wrong. Runs with zero deps:
//   node --test test/image_shrink.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { squareCrop, fitBox } from "../lib/image-shrink.mjs";

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

// Egress (CLAUDE.md): fitBox is the aspect-preserving resize (NOT a crop) used
// for studio-branding photos. The per-bucket caps are the point.
test("fitBox caps the LONGER side and preserves aspect, never upscaling", () => {
  // A 4000×3000 phone photo through each bucket's cap:
  assert.deepEqual(fitBox(4000, 3000, 512), { tw: 512, th: 384 }); // logo ≤512
  assert.deepEqual(fitBox(4000, 3000, 1280), { tw: 1280, th: 960 }); // login/cover/email ≤1280
  assert.deepEqual(fitBox(4000, 3000, 800), { tw: 800, th: 600 }); // class-type ≤800
  // Portrait: the HEIGHT is the longer side and lands on the cap.
  assert.deepEqual(fitBox(1200, 2000, 1280), { tw: 768, th: 1280 });
});

test("fitBox never upscales a small image", () => {
  assert.deepEqual(fitBox(300, 200, 1280), { tw: 300, th: 200 });
  assert.deepEqual(fitBox(512, 512, 512), { tw: 512, th: 512 });
});

test("avatars use the square crop capped at 512", () => {
  assert.equal(squareCrop(2000, 1500, 512).target, 512);
  assert.equal(squareCrop(400, 400, 512).target, 400); // small avatar not upscaled
});
