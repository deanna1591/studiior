// Decision 68 — the one class button's state machine, pure so a client can
// re-evaluate it on a clock (the checkin/reserved boundary is time-relative)
// and a node test can prove every transition. No I/O.
//
// States:
//   "book"                 — not booked; the bookable state
//   "reserved"             — booked, outside the check-in window
//   "waiting_confirmation" — booked, a flex class not yet confirmed (Decision 21)
//   "checkin"              — booked, inside the window, not yet checked in
//   "checked_in"           — checked in by any door (Decision 35)
//   "waitlisted"           — on the waitlist
//   "cancelled"            — the class is cancelled
//
// A holding (pending_payment) seat is NOT this button's concern — the Book list
// renders that itself and does not call this helper for it.
export function classButtonState({
  bookingStatus = null,
  flexPending = false,
  checkedIn = false,
  cancelled = false,
  startsMs,
  endsMs = null,
  opensBeforeMin = 0,
  closesAfterMin = 0,
  nowMs = Date.now(),
} = {}) {
  if (cancelled) return "cancelled";
  if (bookingStatus === "waitlisted") return "waitlisted";

  const isBooked = bookingStatus === "booked" || bookingStatus === "attended";
  if (!isBooked) return "book";

  // Checked in by any door wins — self_check_in flips the booking to 'attended',
  // an instructor/desk scan leaves it 'booked' with a check_ins row (checkedIn).
  if (checkedIn || bookingStatus === "attended") return "checked_in";

  // A flex class awaiting confirmation shows "Waiting for confirmation" in place
  // of Reserved, regardless of the window, until it is confirmed.
  if (flexPending) return "waiting_confirmation";

  const opensAt = startsMs - opensBeforeMin * 60000;
  const closesAt = (endsMs ?? startsMs) + closesAfterMin * 60000;
  if (nowMs >= opensAt && nowMs <= closesAt) return "checkin";
  return "reserved";
}
