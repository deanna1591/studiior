// Email preview sizing — the width rule behind the templates editor preview.
// Runs with zero deps:  node --test test/email_preview_size.test.mjs
// (run-suites.sh is SQL; this is a standalone Node built-in test of the pure
// helper EmailPreview ships, so the rule the preview uses is the rule checked.)
//
// THE RULE (item 1): the preview NEVER overflows its column.
//  - Mobile: iframe width = min(375, column); frame reflows, scale 1.
//  - Desktop: iframe lays out at 600, scales DOWN to the column when narrower.
//  - boxW <= column for every column from 375px up → no horizontal scroll.

import { test } from "node:test";
import assert from "node:assert/strict";
import { previewBox } from "../lib/email-preview-size.mjs";

test("mobile: 375 in a wide column, 1:1", () => {
  const { renderW, scale, boxW } = previewBox({ mode: "mobile", avail: 800 });
  assert.equal(renderW, 375);
  assert.equal(scale, 1);
  assert.equal(boxW, 375);
});

test("mobile: reflows to the column when narrower than 375", () => {
  const { renderW, scale, boxW } = previewBox({ mode: "mobile", avail: 300 });
  assert.equal(renderW, 300); // reflow, not clip
  assert.equal(scale, 1);
  assert.equal(boxW, 300);
});

test("mobile: not measured yet falls back to 375", () => {
  assert.equal(previewBox({ mode: "mobile", avail: 0 }).boxW, 375);
});

test("desktop: 600 at 1:1 in a wide column", () => {
  const { renderW, scale, boxW } = previewBox({ mode: "desktop", avail: 800 });
  assert.equal(renderW, 600);
  assert.equal(scale, 1);
  assert.equal(boxW, 600);
});

test("desktop: scales down to a narrow column", () => {
  const { renderW, scale, boxW } = previewBox({ mode: "desktop", avail: 420 });
  assert.equal(renderW, 600); // lays out at 600
  assert.equal(scale, 0.7); // 420/600
  assert.equal(boxW, 420); // fills the column, never exceeds it
});

test("desktop: not measured yet falls back to 600 at 1:1", () => {
  assert.equal(previewBox({ mode: "desktop", avail: 0 }).boxW, 600);
});

// The guarantee: the rendered box never exceeds the column, from 375px up — a
// 420px preview column (the min above 1100) minus 32px padding = 388 avail, and
// everything down to a tiny pane. boxW <= avail = no horizontal scroll.
test("boxW never exceeds the measured column, 375px up", () => {
  for (const avail of [48, 100, 200, 343, 388, 500, 600, 700, 1000]) {
    for (const mode of ["mobile", "desktop"]) {
      const { boxW } = previewBox({ mode, avail });
      assert.ok(boxW <= avail + 1e-9, `${mode} boxW ${boxW} > column ${avail}`);
    }
  }
});
