import { test } from "node:test";
import assert from "node:assert/strict";
import { freeStage, defaultSortMode } from "../lib/members-list.mjs";

const comp = (status, startsAt) => ({ paymentSource: "comp", status, startsAt });

test("freeStage: an attended comp booking is 'taken' (wins over anything)", () => {
  assert.equal(freeStage([comp("attended", "2026-10-10")]), "taken");
  assert.equal(freeStage([comp("no_show", "2026-10-09"), comp("attended", "2026-10-10")]), "taken");
});

test("freeStage: a still-booked comp booking is 'booked'", () => {
  assert.equal(freeStage([comp("booked", "2026-11-01")]), "booked");
  // booked wins over a no_show (precedence taken > booked > missed)
  assert.equal(freeStage([comp("no_show", "2026-10-01"), comp("booked", "2026-11-01")]), "booked");
});

test("freeStage: only no_show comps and no later booking is 'missed'", () => {
  assert.equal(freeStage([comp("no_show", "2026-10-10")]), "missed");
});

test("freeStage: a no_show with a LATER booking of any kind is not missed (null)", () => {
  assert.equal(freeStage([
    comp("no_show", "2026-10-10"),
    { paymentSource: "class_pack", status: "booked", startsAt: "2026-10-20" },
  ]), null);
  // an earlier booking does not rescue it
  assert.equal(freeStage([
    { paymentSource: "drop_in", status: "attended", startsAt: "2026-10-01" },
    comp("no_show", "2026-10-10"),
  ]), "missed");
});

test("freeStage: a cancelled comp booking does not count", () => {
  assert.equal(freeStage([comp("cancelled", "2026-10-10")]), null);
  assert.equal(freeStage([comp("late_cancelled", "2026-10-10")]), null);
  // a cancelled comp is not a 'later booking' that would rescue a no_show
  assert.equal(freeStage([comp("no_show", "2026-10-10"), comp("cancelled", "2026-10-20")]), "missed");
});

test("freeStage: no comp booking at all is null", () => {
  assert.equal(freeStage([{ paymentSource: "membership", status: "attended", startsAt: "2026-10-10" }]), null);
  assert.equal(freeStage([]), null);
  assert.equal(freeStage(), null);
});

test("defaultSortMode: newest when nobody has visited, else attention", () => {
  assert.equal(defaultSortMode([{ lifetime_visits: 0 }, { lifetime_visits: 0 }]), "newest");
  assert.equal(defaultSortMode([{ lifetime_visits: 0 }, { lifetime_visits: 3 }]), "attention");
  assert.equal(defaultSortMode([]), "newest");                 // empty studio
  assert.equal(defaultSortMode([{}, { lifetime_visits: null }]), "newest");
});
