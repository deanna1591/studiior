// Decision 95 — the pure layer for the flex-rescue move page and its card list.
//
// orderRescueCards mirrors core_classes_for_rescue's SQL ORDER BY (a class with
// a booking first, then by start), capped at 8. spotsLine / moveResultLine /
// MOVE_REFUSALS are the sentences the move page shows, in one place so the page
// and the record cannot drift. No em dashes.

// Decision 95(b): the SQL now leads with flex classes one short ("Needs 1 more"),
// then two short ("Needs 2 more"), then core ("Always runs"). A row with no
// label is core (the pre-95(b) shape). Within flex the order is by start;
// within core a class with a booking first, then by start.
function rescueGroup(r) {
  if (r.label === "Needs 1 more to run" || r.label === "Needs 1 more") return 1;
  if (r.label === "Needs 2 more to run" || r.label === "Needs 2 more") return 2;
  return 3;
}

/** Flex one short, two short, then core (a booked class first, then start), max 8. */
export function orderRescueCards(rows) {
  return (rows ?? [])
    .map((r, i) => ({ r, i }))
    .sort((a, b) => {
      const ga = rescueGroup(a.r), gb = rescueGroup(b.r);
      if (ga !== gb) return ga - gb;
      if (ga < 3) {
        const d = (Date.parse(a.r.starts_at ?? "") || 0) - (Date.parse(b.r.starts_at ?? "") || 0);
        return d || a.i - b.i;
      }
      const ab = (a.r.n_booked ?? 0) > 0 ? 1 : 0;
      const bb = (b.r.n_booked ?? 0) > 0 ? 1 : 0;
      if (ab !== bb) return bb - ab; // booked-first desc
      const at = Date.parse(a.r.starts_at ?? "") || 0;
      const bt = Date.parse(b.r.starts_at ?? "") || 0;
      if (at !== bt) return at - bt; // then by start, ascending
      return a.i - b.i; // stable
    })
    .map((x) => x.r)
    .slice(0, 8);
}

/** "3 in already · 4 spots left" / "4 spots left" for a card. */
export function spotsLine({ n_booked = 0, spots_left = 0 } = {}) {
  const left = `${spots_left} ${spots_left === 1 ? "spot" : "spots"} left`;
  return n_booked > 0 ? `${n_booked} in already · ${left}` : left;
}

/** The success line on the move page. */
export function moveResultLine({ class_name, day, time } = {}) {
  return `You're in. ${class_name || "your class"}, ${day || ""} at ${time || ""}.`;
}

/** A refused move, as a sentence the member reads. */
export const MOVE_REFUSALS = {
  source_confirmed: "That class is already going ahead, so there is nothing to move.",
  already_in_class: "You're already booked into that class.",
  class_full: "That class is full now.",
  class_in_past: "That class has already started.",
  class_not_scheduled: "That class is not running.",
  class_hidden: "That class isn't open for booking.",
  plan_not_covering: "Your plan doesn't cover that class.",
  booking_not_live: "This booking can't be moved.",
  different_studio: "That class is at a different studio.",
  no_such_class: "We couldn't find that class.",
  no_such_booking: "We couldn't find your booking.",
};

export function refusalSentence(reason) {
  return MOVE_REFUSALS[reason] || "We couldn't move your booking. Please try another class.";
}
