import { test } from "node:test";
import assert from "node:assert/strict";
import {
  rangeFor, defaultDate, coreOnlyDefault, filterDays, captionText, monthCells, totalClasses, classLine,
} from "../lib/schedule-post.mjs";

// A fixed grouped sample, the shape schedule_post_data returns.
const DATA = {
  hashtags: "#reform #pilates",
  days: [
    { date: "2026-11-09", label: "Monday 09 Nov", count: 2, classes: [
      { time: "7:00 AM", name: "Reformer Flow", coach: "Ada", tier: "core" },
      { time: "6:00 PM", name: "Mat Pilates", coach: null, tier: "flex" },
    ] },
    { date: "2026-11-11", label: "Wednesday 11 Nov", count: 1, classes: [
      { time: "7:00 AM", name: "Reformer Burn", coach: "Mia", tier: "core" },
    ] },
  ],
};

test("rangeFor: day, week (Mon-based), month", () => {
  assert.deepEqual(rangeFor("day", "2026-11-09"), { from: "2026-11-09", to: "2026-11-09" });
  // 2026-11-11 is a Wednesday -> Mon 9th .. Sun 15th
  assert.deepEqual(rangeFor("week", "2026-11-11"), { from: "2026-11-09", to: "2026-11-15" });
  assert.deepEqual(rangeFor("month", "2026-11-20"), { from: "2026-11-01", to: "2026-11-30" });
  // Feb (leap-safe): 2027 is not a leap year -> 28 days
  assert.deepEqual(rangeFor("month", "2027-02-10"), { from: "2027-02-01", to: "2027-02-28" });
});

test("defaultDate: tomorrow / next Monday / first of next month", () => {
  assert.equal(defaultDate("day", "2026-11-07"), "2026-11-08");
  // 2026-11-07 is a Saturday; this week's Monday is the 2nd; next Monday the 9th
  assert.equal(defaultDate("week", "2026-11-07"), "2026-11-09");
  assert.equal(defaultDate("month", "2026-11-07"), "2026-12-01");
  assert.equal(defaultDate("month", "2026-12-20"), "2027-01-01");
});

test("coreOnlyDefault: on while the flex minimum is above 1", () => {
  assert.equal(coreOnlyDefault(1), false);
  assert.equal(coreOnlyDefault(2), true);
  assert.equal(coreOnlyDefault(0), false);
});

test("filterDays: core-only drops flex classes and empty days", () => {
  const all = filterDays(DATA.days, false);
  assert.equal(totalClasses(all), 3);
  const core = filterDays(DATA.days, true);
  assert.equal(totalClasses(core), 2);                       // the flex Mat Pilates is gone
  assert.equal(core[0].classes.length, 1);
  assert.equal(core[0].count, 1);                            // count recomputed
  assert.equal(core.every((d) => d.classes.every((c) => c.tier === "core")), true);
  // a day left with no core class is dropped
  const onlyFlexDay = filterDays([{ date: "x", label: "X", count: 1, classes: [{ time: "9", name: "Y", coach: null, tier: "flex" }] }], true);
  assert.equal(onlyFlexDay.length, 0);
});

test("grouping: caption keeps classes under their day label, in order", () => {
  const cap = captionText(DATA);
  const lines = cap.split("\n");
  assert.equal(lines[0], "Monday 09 Nov");
  assert.equal(lines[1], "7:00 AM Reformer Flow with Ada");
  assert.equal(lines[2], "6:00 PM Mat Pilates");            // no coach -> no "with"
  assert.equal(lines[3], "");                                // blank line between days
  assert.equal(lines[4], "Wednesday 11 Nov");
  assert.equal(lines[5], "7:00 AM Reformer Burn with Mia");
  assert.equal(lines[lines.length - 1], "#reform #pilates"); // hashtags last
});

test("caption text: empty days -> just the hashtags, or empty", () => {
  assert.equal(captionText({ days: [], hashtags: "#x" }), "#x");
  assert.equal(captionText({ days: [], hashtags: "" }), "");
  assert.equal(captionText({ days: [], hashtags: null }), "");
  assert.equal(classLine({ time: "7:00 AM", name: "Flow", coach: null }), "7:00 AM Flow");
});

test("month summary: a cell per day, count + first three + more", () => {
  const many = {
    days: [{ date: "2026-11-09", label: "Monday 09 Nov", count: 4, classes: [
      { time: "7", name: "A", coach: null, tier: "core" },
      { time: "8", name: "B", coach: null, tier: "core" },
      { time: "9", name: "C", coach: null, tier: "core" },
      { time: "10", name: "D", coach: null, tier: "core" },
    ] }],
  };
  const cells = monthCells(many.days, 3);
  assert.equal(cells.length, 1);
  assert.deepEqual(cells[0].first, ["A", "B", "C"]);
  assert.equal(cells[0].count, 4);
  assert.equal(cells[0].more, 1);
  // a day with no classes is not a cell
  assert.equal(monthCells([{ date: "x", label: "X", count: 0, classes: [] }]).length, 0);
});

// --- Decision 93 slice 3 — caption " with ", auto-fit, undo -------------------
import { fitPlan, bodyHeight, fitScale, FIT, pushSpec, undoStack, canUndo } from "../lib/schedule-post.mjs";

test("slice 3: caption uses ' with ' between class and coach, never an em dash", () => {
  assert.equal(classLine({ time: "7:00 AM", name: "Reformer Flow", coach: "Ada" }), "7:00 AM Reformer Flow with Ada");
  assert.equal(classLine({ time: "6:00 PM", name: "Mat Pilates", coach: null }), "6:00 PM Mat Pilates");
  const cap = captionText(DATA);
  assert.equal(cap.includes("—"), false);                 // no em dash anywhere
  assert.ok(cap.includes("7:00 AM Reformer Flow with Ada"));
});

// A dense week: 6 days, 2 classes each (the Reform seed shape).
function denseWeek(nDays, perDay) {
  return Array.from({ length: nDays }, (_, i) => ({
    date: `2026-11-${String(9 + i).padStart(2, "0")}`,
    label: `Day ${i + 1}`,
    count: perDay,
    classes: Array.from({ length: perDay }, (_, j) => ({ time: `${7 + j}:00 AM`, name: `Class ${j}`, coach: "X", tier: "core" })),
  }));
}

test("slice 3: a short square week fits on one page at full scale", () => {
  const plan = fitPlan({ days: denseWeek(3, 1), mode: "week", format: "square" });
  assert.equal(plan.pages.length, 1);
  assert.equal(plan.pages[0].scale, 1);
  assert.equal(plan.pages[0].parts, 1);
});

test("slice 3: a medium square week auto-fits to a smaller scale, one page", () => {
  const plan = fitPlan({ days: denseWeek(5, 2), mode: "week", format: "square" });
  assert.equal(plan.pages.length, 1);
  assert.ok(plan.pages[0].scale < 1);                     // a step down
  assert.ok(plan.pages[0].scale >= FIT.floor);
});

test("slice 3: a dense square week past the floor splits into parts, days whole", () => {
  const days = denseWeek(6, 2);
  const plan = fitPlan({ days, mode: "week", format: "square" });
  assert.ok(plan.pages.length >= 2);
  plan.pages.forEach((p, i) => { assert.equal(p.part, i + 1); assert.equal(p.parts, plan.pages.length); });
  // every day appears on exactly one page, no day split
  const seen = plan.pages.flatMap((p) => p.days.map((d) => d.date));
  assert.deepEqual([...seen].sort(), days.map((d) => d.date).sort());
  // each page actually fits at its scale
  plan.pages.forEach((p) => assert.ok(bodyHeight(p.days, "week") * p.scale <= FIT.budget));
});

test("slice 3: a dense square DAY splits its classes across parts", () => {
  const day = [{ date: "2026-11-09", label: "Mon", count: 8, classes: Array.from({ length: 8 }, (_, j) => ({ time: `${7 + j}:00`, name: `C${j}`, coach: null, tier: "core" })) }];
  const plan = fitPlan({ days: day, mode: "day", format: "square" });
  assert.ok(plan.pages.length >= 2);
  const total = plan.pages.reduce((n, p) => n + (p.days[0]?.classes.length ?? 0), 0);
  assert.equal(total, 8);                                 // all classes kept, none lost
});

test("slice 3: a story post never splits (it has the room)", () => {
  const plan = fitPlan({ days: denseWeek(6, 3), mode: "week", format: "story" });
  assert.equal(plan.pages.length, 1);
  assert.equal(plan.pages[0].scale, 1);
});

test("slice 3: fitScale picks the first step that fits, else the floor", () => {
  assert.deepEqual(fitScale(100), { scale: 1, fits: true });
  assert.equal(fitScale(FIT.budget * 10).fits, false);
  assert.equal(fitScale(FIT.budget * 10).scale, FIT.floor);
});

// --- Editorial styles (amendment) -------------------------------------------
import {
  POST_STYLES, STYLE_LABELS, headlineParts, shortName, receiptNo, editorialPlan, STYLE_FIT, titleCase, stripLeadingZero,
} from "../lib/schedule-post.mjs";

test("editorial: four styles with labels", () => {
  assert.deepEqual(POST_STYLES, ["guest_check", "times", "invitation", "lock_screen"]);
  assert.equal(STYLE_LABELS.guest_check, "Guest Check");
  assert.equal(STYLE_LABELS.lock_screen, "Lock screen");
});

test("editorial: headline — all classes puts 'schedule' in the accent", () => {
  assert.deepEqual(headlineParts({ mode: "week" }), { lead: "this week's ", accent: "schedule" });
  assert.deepEqual(headlineParts({ mode: "day", weekday: "Monday" }), { lead: "Monday's ", accent: "schedule" });
  assert.deepEqual(headlineParts({ mode: "month", monthName: "November" }), { lead: "November's ", accent: "schedule" });
});

test("editorial: headline — coach mode names the coach", () => {
  assert.deepEqual(headlineParts({ mode: "week", coachFirst: "Ada" }), { lead: "Ada's ", accent: "week" });
  assert.deepEqual(headlineParts({ mode: "day", weekday: "Monday", coachFirst: "Ada" }), { lead: "Ada on ", accent: "Monday" });
  assert.deepEqual(headlineParts({ mode: "month", monthName: "November", coachFirst: "Ada" }), { lead: "Ada's ", accent: "November" });
});

test("editorial: shortName is the first word; receiptNo is month+day", () => {
  assert.equal(shortName("Reform Collective"), "Reform");
  assert.equal(shortName("  RPC  "), "RPC");
  assert.equal(receiptNo("2026-11-09"), "N° 1109");
});

test("editorial: caption starts with the coach's name in coach mode", () => {
  const cap = captionText({ days: DATA.days, hashtags: "#x", coachFirst: "Ada" });
  assert.ok(cap.startsWith("Ada's classes\n\n"));
  assert.ok(cap.includes("7:00 AM Reformer Flow with Ada"));
  // no coach -> no prefix (unchanged)
  assert.ok(!captionText({ days: DATA.days, hashtags: "#x" }).startsWith("Ada"));
});

test("editorial: The Times week is one page (the grid never splits)", () => {
  const plan = editorialPlan({ days: denseWeek(7, 9), mode: "week", format: "square", style: "times" });
  assert.equal(plan.pages.length, 1);
  assert.equal(plan.pages[0].scale >= STYLE_FIT.times.floor, true);
});

test("editorial: a light per-class week fits one page; a dense one splits by whole days", () => {
  for (const style of ["guest_check", "invitation"]) {
    const light = editorialPlan({ days: denseWeek(5, 1), mode: "week", format: "square", style });
    assert.equal(light.pages.length, 1, style);
    const dense = editorialPlan({ days: denseWeek(7, 9), mode: "week", format: "square", style });
    assert.ok(dense.pages.length >= 2, style);                               // dense week splits
    dense.pages.forEach((p, i) => { assert.equal(p.part, i + 1); assert.equal(p.parts, dense.pages.length); });
    // every day appears on exactly one page, no day torn across parts
    const seen = dense.pages.flatMap((p) => p.days.map((d) => d.date));
    assert.deepEqual([...seen].sort(), denseWeek(7, 9).map((d) => d.date).sort(), style);
  }
});

test("editorial: a short day fits one page; a dense day splits, classes whole", () => {
  const short = editorialPlan({ days: denseWeek(1, 4), mode: "day", format: "square", style: "invitation" });
  assert.equal(short.pages.length, 1);
  assert.equal(short.pages[0].scale, 1);
  const dense = editorialPlan({ days: denseWeek(1, 30), mode: "day", format: "square", style: "invitation" });
  assert.ok(dense.pages.length >= 2);
  const total = dense.pages.reduce((n, p) => n + (p.days[0]?.classes.length ?? 0), 0);
  assert.equal(total, 30);                                 // none lost
  dense.pages.forEach((p, i) => { assert.equal(p.part, i + 1); assert.equal(p.parts, dense.pages.length); });
});

test("editorial: a story post never splits; the month grid never splits", () => {
  assert.equal(editorialPlan({ days: denseWeek(1, 30), mode: "day", format: "story", style: "invitation" }).pages.length, 1);
  assert.equal(editorialPlan({ days: denseWeek(20, 4), mode: "month", format: "square", style: "times" }).pages.length, 1);
});

test("editorial: lock screen is day only and splits a dense day", () => {
  const plan = editorialPlan({ days: denseWeek(1, 14), mode: "day", format: "square", style: "lock_screen" });
  assert.ok(plan.pages.length >= 2);
  const total = plan.pages.reduce((n, p) => n + (p.days[0]?.classes.length ?? 0), 0);
  assert.equal(total, 14);
});

// --- Amendment: story parts + lock screen -----------------------------------

// A week of exactly 60 classes across 7 days (9,9,9,9,8,8,8).
function week60() {
  const per = [9, 9, 9, 9, 8, 8, 8];
  return per.map((n, i) => ({
    date: `2026-11-${String(9 + i).padStart(2, "0")}`,
    label: `Day ${i + 1}`,
    count: n,
    classes: Array.from({ length: n }, (_, j) => ({ time: `${7 + j}:00 AM`, name: `D${i}C${j}`, coach: "X", tier: "core" })),
  }));
}

test("story parts: a 60-class Guest Check week story gives 2+ pages, every class once, no day split", () => {
  const days = week60();
  const plan = editorialPlan({ days, mode: "week", format: "story", style: "guest_check" });
  assert.ok(plan.pages.length >= 2, `pages=${plan.pages.length}`);
  // every class appears exactly once
  const total = plan.pages.reduce((n, p) => n + p.days.reduce((m, d) => m + d.classes.length, 0), 0);
  assert.equal(total, 60);
  // each day is whole: it appears on exactly one page with its full class count
  const inputByDate = new Map(days.map((d) => [d.date, d.classes.length]));
  const seen = new Map();
  plan.pages.forEach((p) => p.days.forEach((d) => {
    assert.equal(seen.has(d.date), false, `day ${d.date} split across pages`);
    seen.set(d.date, d.classes.length);
    assert.equal(d.classes.length, inputByDate.get(d.date), `day ${d.date} torn`);
  }));
  assert.equal(seen.size, 7);
  plan.pages.forEach((p, i) => { assert.equal(p.part, i + 1); assert.equal(p.parts, plan.pages.length); });
});

test("story parts: square gives more pages than story (story has the room)", () => {
  const days = week60();
  const story = editorialPlan({ days, mode: "week", format: "story", style: "guest_check" });
  const square = editorialPlan({ days, mode: "week", format: "square", style: "guest_check" });
  assert.ok(square.pages.length > story.pages.length, `square=${square.pages.length} story=${story.pages.length}`);
});

test("story parts: a month story is one page", () => {
  const plan = editorialPlan({ days: denseWeek(20, 4), mode: "month", format: "story", style: "guest_check" });
  assert.equal(plan.pages.length, 1);
});

test("lock screen: a 16-class day gives 6 square pages / 4 story pages in time order", () => {
  const day = [{
    date: "2026-11-10", label: "Tuesday 10 Nov", count: 16,
    classes: Array.from({ length: 16 }, (_, j) => ({ time: `${7 + j}:00`, name: `C${j}`, coach: "X", tier: j % 2 ? "flex" : "core" })),
  }];
  const sq = editorialPlan({ days: day, mode: "day", format: "square", style: "lock_screen" });
  const st = editorialPlan({ days: day, mode: "day", format: "story", style: "lock_screen" });
  assert.equal(sq.pages.length, 6);   // ceil(16/3)
  assert.equal(st.pages.length, 4);   // ceil(16/5)
  // both carry all 16 classes in the original time order
  for (const plan of [sq, st]) {
    const names = plan.pages.flatMap((p) => p.days[0].classes.map((c) => c.name));
    assert.deepEqual(names, Array.from({ length: 16 }, (_, j) => `C${j}`));
    assert.equal(plan.pages.every((p) => p.scale === 1), true);  // no scaling
  }
});

test("lock screen: titleCase makes an all-caps class name read as a title", () => {
  assert.equal(titleCase("REFORMER SCULPT"), "Reformer Sculpt");
  assert.equal(titleCase("reformer flow"), "Reformer Flow");
  assert.equal(titleCase("Mat Pilates"), "Mat Pilates");
});

test("amendment: the lock-screen clock drops a leading zero but keeps a two-digit hour", () => {
  assert.equal(stripLeadingZero("06:00"), "6:00");
  assert.equal(stripLeadingZero("12:00"), "12:00");
  assert.equal(stripLeadingZero("7:00"), "7:00");
});

test("amendment: a split week's total counts every class in the whole week, the same on every part", () => {
  const days = week60();
  const plan = editorialPlan({ days, mode: "week", format: "story", style: "guest_check" });
  assert.ok(plan.pages.length >= 2);            // the week splits into parts
  assert.equal(totalClasses(days), 60);         // the whole-week total handed to every part
  // the parts together still cover all 60 classes exactly once
  const covered = plan.pages.reduce((n, pg) => n + totalClasses(pg.days), 0);
  assert.equal(covered, 60);
});

test("slice 3: the undo stack pushes and steps back, base kept", () => {
  const base = { v: 0 };
  let s = [base];
  assert.equal(canUndo(s), false);
  s = pushSpec(s, { v: 1 });
  s = pushSpec(s, { v: 2 });
  assert.equal(canUndo(s), true);
  let r = undoStack(s);
  assert.deepEqual(r.current, { v: 1 });
  assert.equal(r.stack.length, 2);
  r = undoStack(r.stack);
  assert.deepEqual(r.current, base);                      // back to the base
  assert.equal(canUndo(r.stack), false);
  // undoing at the base is a no-op (never pops the base away)
  const r2 = undoStack(r.stack);
  assert.deepEqual(r2.current, base);
  assert.equal(r2.stack.length, 1);
});

// --- Amendment: week rows, watermark fallback -------------------------------
import { weekRows, anyFlex } from "../lib/schedule-post.mjs";
import { editResult } from "../lib/post-edit.mjs";

test("amendment: week rows list every class time from a two-day fixture", () => {
  const days = [
    { date: "2026-11-09", label: "Monday 09 Nov", count: 2, classes: [
      { time: "7:00 AM", name: "Reformer Flow", coach: "Ada", tier: "core" },
      { time: "6:00 PM", name: "Mat Pilates", coach: "Bea", tier: "flex" },
    ] },
    { date: "2026-11-10", label: "Tuesday 10 Nov", count: 1, classes: [
      { time: "9:30 AM", name: "Barre", coach: null, tier: "core" },
    ] },
  ];
  const groups = weekRows(days);
  assert.equal(groups.length, 2);
  const times = groups.flatMap((g) => g.classes.map((c) => c.time));
  for (const t of ["7:00 AM", "6:00 PM", "9:30 AM"]) assert.ok(times.includes(t), t);
  // tier icon: core ✦, flex ○; coach carried, "with " prefix; coach mode drops it
  assert.equal(groups[0].classes[0].icon, "✦");
  assert.equal(groups[0].classes[1].icon, "○");
  assert.equal(groups[0].classes[0].coach, "with Ada");
  assert.equal(weekRows(days, { coachMode: true })[0].classes[0].coach, "");
  assert.equal(anyFlex(days), true);
  assert.equal(anyFlex([days[1]]), false);
});

test("amendment: photo fallback returns ok with background_image when the reply is not JSON", () => {
  const current = { colors: {}, display_font: "Inter", body_font: "Inter", layout: "list", radius: "small", tone: "", logo_placement: "top-left", background_treatment: "none" };
  const path = "studio/2026-11/edit-1.jpg";
  const r = editResult(null, { photoPath: path, current });
  assert.equal(r.ok, true);
  assert.equal(r.spec.background_image, path);
  assert.equal(r.spec.background_treatment, "full");
  assert.equal(r.spec.overlay_strength, 0.85);
  assert.ok(/Photo applied/.test(r.note));
  // no photo + unreadable reply -> not ok
  assert.equal(editResult(null, { current }).ok, false);
  // a valid spec + a photo -> the photo is forced onto it
  const spec = { ...current, background_treatment: "none" };
  const r2 = editResult(spec, { photoPath: path, current });
  assert.equal(r2.ok, true);
  assert.equal(r2.spec.background_image, path);
  assert.equal(r2.spec.background_treatment, "full");
});
