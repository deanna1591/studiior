/**
 * Every failure reason book_class() can return, in the member's words.
 *
 * The gate itself lives in SQL and is not duplicated here — this maps a code to
 * a sentence, nothing more. An unmapped code falls through to the raw code
 * rather than a generic "cannot book", because Business Rules §2.1 requires the
 * member to be told which rule stopped them.
 *
 * In a plain module (not a "use server" file, which may only export async
 * functions) so both the member booking actions and the Decision 88 checkout
 * actions share the one map.
 */
export const REASONS: Record<string, string> = {
  not_found: "That class no longer exists.",
  member_not_found: "We could not find your membership record.",
  member_wrong_studio: "That class belongs to a different studio.",
  not_authorised: "You are not allowed to book that.",
  unsupported_payment_source: "That payment method cannot be chosen here.",
  class_cancelled: "That class has been cancelled.",
  class_completed: "That class has already finished.",
  class_in_past: "That class has already started.",
  class_ended: "That class has already ended.",
  outside_booking_window: "That class is further ahead than you can book yet.",
  // Decision 25. The other "not yet": the MONTH is not on the timetable, which
  // is about the class rather than about how far ahead this member may book.
  month_not_published: "That month's timetable has not been published yet.",
  past_booking_cutoff: "Booking has closed for that class.",
  waiver_not_signed: "Please sign the studio waiver before booking.",
  // Decision 34 Part B: require_waiver is on but the studio hasn't published one.
  waiver_unavailable: "This studio hasn't published its waiver yet — please ask the studio.",
  member_not_active: "Your membership is not active.",
  already_booked: "You are already on the list for that class.",
  daily_limit_reached: "You have reached your class limit for that day.",
  future_limit_reached: "You have reached your limit of classes booked ahead.",
  class_type_not_in_plan: "Your plan does not cover that class type.",
  class_full: "That class is full and has no waitlist.",
  waitlist_closed: "The waitlist has closed for that class.",
  // Decision 30 belt: an eligible member's first class is free — the UI routes
  // them to the free path, so this is only reached by a direct call.
  use_free_first: "Your first class here is free — book it as your free class.",
  // Decision 73: the studio caps how many unpaid bookings a member may hold.
  pay_first: "Pay for your booked class first, or pay at the desk when you come in.",
  // Decision 73: a provisional free first class blocks other bookings until it's confirmed.
  free_first_pending: "Your free first class isn't confirmed yet — you can book more once it is.",
  // Decision 73 (c): pay at the desk has been turned off for this member.
  desk_pay_blocked: "Pay online to book. Paying at the desk is not available on this account.",
  // Decision 98: a same-person twin has already had a free class.
  duplicate: "It looks like you've had a free class with us before. You can still book this one by paying.",
  // Decision 100: staff pinned a plan in the "Pay with" dropdown that does not
  // cover this class type.
  plan_not_covering: "That plan does not cover this class.",
  // Decision 48: a class with no instructor assigned yet.
  not_staffed_yet: "No coach is assigned to this class yet.",
  // Decision 91: a class hidden from members.
  class_hidden: "This class is hidden from members.",
  // Decision 24: a plan that does not cover peak classes.
  peak_not_allowed: "Their plan does not cover peak classes.",
  // Decision 49: a paused membership.
  membership_frozen: "Their membership is paused.",
  // Decision 30 free-first eligibility refusals (staff "free first class" path).
  already_had_free: "Their free first class has already been used.",
  already_member: "They are already a member, so the free class does not apply.",
  not_first: "The free class is for first-timers only.",
  missed: "They missed their free class, so it counts as used.",
  late_cancel: "They cancelled their free class late, so it counts as used.",
  not_enabled: "Free first classes are off for this studio.",
  // Decision 30(e): free-first on a flex class is off (core-only), no override given.
  flex_not_allowed: "This class isn't open for a free first class.",
  not_trial_class: "This class isn't open for a free first class.",
  free_first_closed_here: "This class isn't open for a free first class.",
  free_seats_full: "The free first-class spots for this class are full.",
  no_reservation_fee: "Free first classes don't carry a reservation fee here.",
};
