// Decision 77b — the closure-notice form helpers. Zero deps:
//   node --test test/closure-notice.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { resumeDefault, beyondHorizon, longDate, previewSystemBlock } from "../lib/closure-notice.mjs";

test("resumeDefault: ends_on + 1 day, with the month/year roll", () => {
  assert.equal(resumeDefault("2026-11-08"), "2026-11-09");
  assert.equal(resumeDefault("2026-11-30"), "2026-12-01");
  assert.equal(resumeDefault("2026-12-31"), "2027-01-01");
  assert.equal(resumeDefault("not-a-date"), "");
});

test("beyondHorizon: true only when resume is past today + horizon days", () => {
  // today 1 Nov, horizon 60 → last generated day is 31 Dec.
  assert.equal(beyondHorizon("2026-12-15", "2026-11-01", 60), false);
  assert.equal(beyondHorizon("2026-12-31", "2026-11-01", 60), false);
  assert.equal(beyondHorizon("2027-01-01", "2026-11-01", 60), true);
  assert.equal(beyondHorizon("2027-02-01", "2026-11-01", 60), true);
  assert.equal(beyondHorizon("", "2026-11-01", 60), false);
});

test("longDate: a tz-less calendar date", () => {
  assert.equal(longDate("2026-11-16"), "Monday 16 November 2026");
  assert.equal(longDate("bad"), "");
});

test("previewSystemBlock: with a cancelled list — the resume line + a book link", () => {
  const b = previewSystemBlock({ resumesOn: "2026-11-16", sampleCancelled: ["Reformer Flow · Mon 09 Nov 07:00"] });
  assert.match(b.html, /These classes of yours were cancelled/);
  assert.match(b.html, /<li>Reformer Flow · Mon 09 Nov 07:00<\/li>/);
  assert.match(b.html, /Classes resume Monday 16 November 2026\./);
  assert.match(b.html, /Book your week/);
  assert.match(b.text, /Your credit \(or free first class\) is back\./);
});

test("previewSystemBlock: no cancelled list — just the resume line and link", () => {
  const b = previewSystemBlock({ resumesOn: "2026-11-16" });
  assert.ok(!/were cancelled/.test(b.html));
  assert.match(b.html, /Classes resume Monday 16 November 2026\./);
  assert.match(b.text, /Classes resume Monday 16 November 2026\./);
});
