import { test } from "node:test";
import assert from "node:assert/strict";
import { orderRescueCards, spotsLine, moveResultLine, refusalSentence, MOVE_REFUSALS } from "../lib/flex-rescue.mjs";

test("cards with a booking come first, then by start", () => {
  const rows = [
    { occurrence_id: "a", n_booked: 0, starts_at: "2026-11-12T09:00:00Z" },
    { occurrence_id: "b", n_booked: 2, starts_at: "2026-11-13T09:00:00Z" },
    { occurrence_id: "c", n_booked: 5, starts_at: "2026-11-12T08:00:00Z" },
    { occurrence_id: "d", n_booked: 0, starts_at: "2026-11-11T07:00:00Z" },
  ];
  const got = orderRescueCards(rows).map((r) => r.occurrence_id);
  // booked first (c before b, by start), then the rest by start (d before a)
  assert.deepEqual(got, ["c", "b", "d", "a"]);
});

test("the list is capped at 8 and the order is stable", () => {
  const rows = Array.from({ length: 12 }, (_, i) => ({
    occurrence_id: `o${i}`, n_booked: 1, starts_at: `2026-11-12T0${i % 9}:00:00Z`,
  }));
  const got = orderRescueCards(rows);
  assert.equal(got.length, 8);
  // all booked, equal-start ties keep input order (stable)
  assert.equal(got[0].occurrence_id, "o0");
});

test("empty / nullish input gives an empty list", () => {
  assert.deepEqual(orderRescueCards(null), []);
  assert.deepEqual(orderRescueCards(undefined), []);
  assert.deepEqual(orderRescueCards([]), []);
});

test("spotsLine reads the booking count then the seats", () => {
  assert.equal(spotsLine({ n_booked: 3, spots_left: 4 }), "3 in already · 4 spots left");
  assert.equal(spotsLine({ n_booked: 0, spots_left: 2 }), "2 spots left");
  assert.equal(spotsLine({ n_booked: 0, spots_left: 1 }), "1 spot left");
});

test("the success line names the class, day and time", () => {
  assert.equal(
    moveResultLine({ class_name: "Reformer Flow", day: "Friday 13 November", time: "18:30" }),
    "You're in. Reformer Flow, Friday 13 November at 18:30.",
  );
});

test("every refusal maps to a sentence, with a fallback", () => {
  for (const key of ["source_confirmed", "already_in_class", "class_full", "class_in_past", "class_hidden", "plan_not_covering"]) {
    assert.ok(MOVE_REFUSALS[key] && MOVE_REFUSALS[key].length > 0);
    assert.equal(refusalSentence(key), MOVE_REFUSALS[key]);
  }
  assert.equal(refusalSentence("something_unknown"), "We couldn't move your booking. Please try another class.");
});

test("no em dashes in any move-page sentence", () => {
  const all = [...Object.values(MOVE_REFUSALS),
    moveResultLine({ class_name: "X", day: "Y", time: "Z" }),
    spotsLine({ n_booked: 1, spots_left: 1 })];
  for (const s of all) assert.ok(!/—/.test(s), s);
});
