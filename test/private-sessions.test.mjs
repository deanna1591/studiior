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

// Decision 116(b): a private keeps the class's coach.
const ROWS = [
  // 09:00 a free hour: two coaches available
  { starts_at: "2026-11-23T01:00:00+00:00", coach_ids: ["hub", "kai"], replaces_occurrence_id: null },
  // 10:00 an empty class: only its own coach
  { starts_at: "2026-11-23T02:00:00+00:00", coach_ids: ["hub"], replaces_occurrence_id: "occ-1" },
  // 11:00 two rooms, two empty classes, two different coaches
  { starts_at: "2026-11-23T03:00:00+00:00", coach_ids: ["kai"], replaces_occurrence_id: "occ-2" },
  { starts_at: "2026-11-23T03:00:00+00:00", coach_ids: ["ada"], replaces_occurrence_id: "occ-3" },
];

test("mergeSlots: one entry per start, coaches carried, replacement marked, keys normalised", async () => {
  const { mergeSlots, slotReplaces } = await import("../lib/private-sessions.mjs");
  const s = mergeSlots(ROWS);
  assert.deepEqual(s.map((x) => x.start), ["2026-11-23T01:00:00.000Z", "2026-11-23T02:00:00.000Z", "2026-11-23T03:00:00.000Z"]);
  assert.deepEqual(s[0].coaches.map((c) => c.id), ["hub", "kai"]);
  assert.equal(slotReplaces(s[0]), false);
  assert.equal(slotReplaces(s[1]), true);
  assert.deepEqual(s[2].coaches.map((c) => c.id), ["kai", "ada"]);
});

test("the coach filter: all coaches shows every time; one coach only theirs, narrowed to them", async () => {
  const { mergeSlots, slotsForCoach } = await import("../lib/private-sessions.mjs");
  const s = mergeSlots(ROWS);
  assert.equal(slotsForCoach(s, null).length, 3);
  const hub = slotsForCoach(s, "hub");
  assert.deepEqual(hub.map((x) => x.start), ["2026-11-23T01:00:00.000Z", "2026-11-23T02:00:00.000Z"]);
  assert.ok(hub.every((x) => x.coaches.length === 1 && x.coaches[0].id === "hub"));
  const ada = slotsForCoach(s, "ada");
  assert.deepEqual(ada.map((x) => x.start), ["2026-11-23T03:00:00.000Z"]);
  assert.equal(slotsForCoach(s, "nobody").length, 0);
});

test("the coach step is skipped when the time has one coach, asked when it has several", async () => {
  const { mergeSlots, slotsForCoach, coachStep } = await import("../lib/private-sessions.mjs");
  const s = mergeSlots(ROWS);
  assert.deepEqual(coachStep(s[1]), { skip: true, coachId: "hub", choices: [] });
  assert.deepEqual(coachStep(s[0]), { skip: false, coachId: null, choices: ["hub", "kai"] });
  assert.deepEqual(coachStep(s[2]), { skip: false, coachId: null, choices: ["kai", "ada"] });
  // with a coach filter set, every time has one coach, so the step is always skipped
  for (const x of slotsForCoach(s, "kai")) assert.equal(coachStep(x).skip, true);
  assert.equal(coachStep(null).skip, false);
});

test("no 'any coach' wording is left in the member flow", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../app/member/book/private/flow.tsx", import.meta.url), "utf8");
  assert.ok(!/Any coach/.test(src));
  assert.ok(/All coaches/.test(src));
});
