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
