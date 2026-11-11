// Decision 95 — the pure layer for the flex-rescue move page and its card list.
//
// orderRescueCards mirrors core_classes_for_rescue's SQL ORDER BY (a class with
// a booking first, then by start), capped at 8. spotsLine / moveResultLine /
// MOVE_REFUSALS are the sentences the move page shows, in one place so the page
// and the record cannot drift. No em dashes.

/** Classes with a booking first, then by start, max 8 (the SQL order). */
export function orderRescueCards(rows) {
  return (rows ?? [])
    .map((r, i) => ({ r, i }))
    .sort((a, b) => {
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
