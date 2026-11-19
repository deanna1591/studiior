import { test } from "node:test";
import assert from "node:assert/strict";
import {
  groupGaps, gapsPerWeekday, cancelIsOnTime, cancelNoticeLine, privateReasonSentence, vatSplit,
} from "../lib/private-sessions.mjs";
import { giftAmountProblem, isGiftCode, cardLayout, contrastRatio } from "../lib/gift-card.mjs";

const iso = (s) => new Date(s).toISOString();

test("groupGaps: contiguous 30-minute starts form one gap; a break starts another", () => {
  const g = groupGaps([iso("2026-11-23T00:00Z"), iso("2026-11-23T00:30Z"), iso("2026-11-23T01:00Z"),
                       iso("2026-11-23T03:00Z"), iso("2026-11-23T03:30Z")]);
  assert.equal(g.length, 2);
  assert.equal(g[0].starts.length, 3);
  assert.equal(g[1].from, iso("2026-11-23T03:00Z"));
});

test("groupGaps: order and duplicates do not matter", () => {
  const g = groupGaps([iso("2026-11-23T01:00Z"), iso("2026-11-23T00:30Z"), iso("2026-11-23T00:30Z")]);
  assert.equal(g.length, 1);
  assert.equal(g[0].from, iso("2026-11-23T00:30Z"));
});

test("gapsPerWeekday counts gaps by STUDIO-local weekday (Manila Monday 07:00 is Sunday 23:00 UTC)", () => {
  const starts = [
    iso("2026-11-22T23:00Z"), iso("2026-11-22T23:30Z"),  // Mon 07:00, 07:30 Manila — one gap
    iso("2026-11-23T05:00Z"),                            // Mon 13:00 Manila — a second gap
    iso("2026-11-24T02:00Z"),                            // Tue 10:00 Manila
  ];
  const c = gapsPerWeekday(starts, "Asia/Manila");
  assert.equal(c.Mon, 2);
  assert.equal(c.Tue, 1);
  assert.equal(c.Sun, 0);
});

test("cancel rule: on time before start minus lead, late after", () => {
  const start = Date.parse("2026-11-25T10:00:00Z");
  assert.equal(cancelIsOnTime(start, 12, Date.parse("2026-11-24T21:59:00Z")), true);
  assert.equal(cancelIsOnTime(start, 12, Date.parse("2026-11-24T22:00:00Z")), false);
  const fmt = () => "Tue 6:00 PM";
  assert.match(cancelNoticeLine({ startsMs: start, leadHours: 12, nowMs: start - 13 * 3600e3, fmt }), /^Free to cancel or move until Tue 6:00 PM/);
  assert.match(cancelNoticeLine({ startsMs: start, leadHours: 12, nowMs: start - 3600e3, fmt }), /less than 12 hours/);
  assert.equal(cancelNoticeLine({ startsMs: start, leadHours: 12, nowMs: start + 1, fmt }), "This session has started.");
});

test("every reason has a sentence, with a fallback, and no em dash", () => {
  assert.match(privateReasonSentence("already_moved"), /once/);
  assert.equal(privateReasonSentence("nope"), "That didn't work. Please try again.");
  for (const r of ["too_soon", "coach_unavailable", "pack_1to1_only", "already_moved"]) {
    assert.ok(!privateReasonSentence(r).includes("—"));
  }
});

test("VAT split: 12 percent inclusive", () => {
  assert.deepEqual(vatSplit(300000), { netCents: 267857, vatCents: 32143 });
});

test("gift amount: whole hundreds from the minimum", () => {
  assert.equal(giftAmountProblem(50000), null);
  assert.equal(giftAmountProblem(250000), null);
  assert.equal(giftAmountProblem(50050), "Choose an amount in whole hundreds.");
  assert.match(giftAmountProblem(40000), /smallest gift card is 500/);
  assert.equal(giftAmountProblem(0), "Choose an amount.");
});

test("gift code shape", () => {
  assert.equal(isGiftCode("REFO-NMMG-WCCA"), true);
  assert.equal(isGiftCode("REFO-N0MG-WCCA"), false);
  assert.equal(isGiftCode("x"), false);
});

test("card layout: the default card ink reads at 4.5:1 on any accent", () => {
  for (const a of ["#BEF738", "#B85C38", "#1E2A5A", "#F2BFCD", "#57534E", "#FFFFFF", "#000000"]) {
    const l = cardLayout({ accent: a, hasImage: false });
    assert.ok(contrastRatio(l.background, l.ink) >= 4.5, `${a} -> ${l.ink}`);
  }
  const img = cardLayout({ accent: "#B85C38", hasImage: true });
  assert.equal(img.background, null);
  assert.equal(img.ink, "#FFFFFF");
});

test("a replacement start keyed as PostgREST returns it still matches groupGaps' keys once normalised", async () => {
  const { groupGaps } = await import("../lib/private-sessions.mjs");
  const raw = ["2026-11-23T13:00:00+00:00", "2026-11-23T14:00:00+00:00"];
  const keys = groupGaps(raw).flatMap((g) => g.starts);
  // the raw form never matches (the bug); the normalised form does (the fix)
  assert.equal(keys.includes(raw[1]), false);
  assert.equal(keys.includes(new Date(raw[1]).toISOString()), true);
});
