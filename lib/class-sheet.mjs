// Decision 68 FIX A — the class-detail sheet's view.
//
// The member's OWN relationship to the class wins over the room's capacity, the
// same rule the schedule's four-state button follows. Reuses classButtonState
// (so the sheet and the Book list can never disagree) and adds the one thing the
// button does not decide: for a member with no booking, book vs join-the-waitlist
// (which needs the capacity + whether a waitlist is on). Returns the state, the
// actions the sheet offers, and whether the capacity line is hidden.
import { classButtonState } from "./class-button.mjs";

export function classSheetView(input = {}) {
  const { full = false, waitlistEnabled = false, freeFirstEligible = false } = input;
  const state = classButtonState(input);

  // The member has a status of their own → it wins, and the capacity line is hidden.
  const ownStatus = state === "reserved" || state === "checkin" || state === "checked_in"
    || state === "waiting_confirmation" || state === "waitlisted";

  let actions;
  switch (state) {
    case "checked_in":           actions = []; break;                 // no actions; status wins
    case "checkin":              actions = ["checkin", "cancel"]; break;
    case "reserved":             actions = ["cancel"]; break;
    case "waiting_confirmation": actions = ["cancel"]; break;
    case "waitlisted":           actions = ["leave"]; break;
    // book / cancelled → a member with no live booking: book, or join the waitlist.
    default:
      actions = full
        ? (waitlistEnabled ? ["waitlist"] : [])
        : [freeFirstEligible ? "bookfree" : "book"];
  }

  return { state, actions, hideCapacity: ownStatus };
}

// Decision 88 (+ Decision 30, 88 addendum) — where "Book" goes for a member with
// NO live booking on a class that is not past and not already checked in. This is
// the one precedence the class page's Book branch follows, extracted so it is
// tested rather than living only in a JSX ternary:
//
//   1. free-first eligible  → "free"      (Decision 30: the free seat, no checkout)
//   2. full                 → "waitlist" | "full"
//   3. a plan covers it     → "book"      (books inline, unchanged)
//   4. otherwise            → "checkout"  (Decision 88: /checkout to pick a plan)
//
// Free-first is checked FIRST and short-circuits, so an eligible member books
// free and NEVER routes to checkout — whatever the coverage answer (the 88
// addendum: "Free first class comes first", "The checkout never shows a free
// option"). The free-vs-full order matches the shipped page exactly.
export function bookRoute({ freeFirstEligible = false, full = false, waitlistEnabled = false, covered = true } = {}) {
  if (freeFirstEligible) return "free";
  if (full) return waitlistEnabled ? "waitlist" : "full";
  return covered ? "book" : "checkout";
}
