import { test } from "node:test";
import assert from "node:assert/strict";
import { relativeDay } from "../lib/relative-day.mjs";
const TZ = "Asia/Manila";
const now = new Date("2026-11-15T06:00:00Z"); // 14:00 Manila, 15 Nov
const at = (localYmd, h = "04:00") => new Date(`${localYmd}T${h}:00+08:00`);

test("today / yesterday", () => {
  assert.equal(relativeDay(at("2026-11-15").toISOString(), TZ, now), "Today");
  assert.equal(relativeDay(at("2026-11-14").toISOString(), TZ, now), "Yesterday");
});
test("days and weeks ago", () => {
  assert.equal(relativeDay(at("2026-11-12").toISOString(), TZ, now), "3 days ago");
  assert.equal(relativeDay(at("2026-11-08").toISOString(), TZ, now), "1 week ago");
  assert.equal(relativeDay(at("2026-10-25").toISOString(), TZ, now), "3 weeks ago");
});
test("older falls back to a date, null for no visit", () => {
  const r = relativeDay(at("2026-08-01").toISOString(), TZ, now);
  assert.match(r, /Aug/);
  assert.equal(relativeDay(null, TZ, now), null);
});
test("a future/same instant reads Today", () => {
  assert.equal(relativeDay(at("2026-11-16").toISOString(), TZ, now), "Today");
});
