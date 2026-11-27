// Decision 78c / 80c / 80d — which notification templates a studio may edit in
// the composer, grouped for the Templates list. Keys must match
// notification_templates.key. Each carries:
//   label    — the human name shown in the list and at the top of its screen
//   audience — who receives it: "Members" | "Instructors" | "Staff"
//   when     — one line, the real trigger (written from the sender that queues it)
//   feature  — (optional) the studio feature it belongs to; the key is hidden
//              from the list while that feature is off (not deleted, switch kept).
// The placeholders shown beside the editor are derived from the default wording,
// so they cannot drift from what render_notification actually substitutes.

export const TEMPLATE_GROUPS = [
  {
    title: "Bookings",
    keys: [
      { key: "booking_confirmed", label: "Booking confirmed", audience: "Members", when: "When a member books a class with a plan or as a drop-in" },
      { key: "free_booking_pending", label: "Free first class — waiting for confirmation", audience: "Members", when: "When a first-timer books their free class and it still needs confirming", feature: "free_first" },
      { key: "free_booking_confirmed", label: "Free first class — confirmed", audience: "Members", when: "When a free first class is confirmed to run", feature: "free_first" },
      { key: "free_booking_not_confirmed", label: "Free first class — not confirmed", audience: "Members", when: "When a free first class does not reach confirmation by the cut-off", feature: "free_first" },
      { key: "free_rescue_2days", label: "Free first class rescue — 2 days before", audience: "Members", when: "2 days before a free first class booked into an under-minimum flex class, offering a move to a core class", feature: "free_first" },
      { key: "free_rescue_final", label: "Free first class rescue — last call", audience: "Members", when: "A few hours before the flex cut-off, a last offer to move a free first class to a core class", feature: "free_first" },
      { key: "free_reservation_nudge", label: "Free first class — reservation fee reminder", audience: "Members", when: "24 hours before the class, to an unpaid free seat", feature: "free_first" },
      { key: "free_reservation_last_call", label: "Free first class — reservation fee last call", audience: "Members", when: "3 hours before the pay deadline, to an unpaid free seat", feature: "free_first" },
      { key: "free_reservation_credited", label: "Free first class — reservation fee credited", audience: "Members", when: "After a first-timer checks in, their reservation fee becomes account credit", feature: "free_first" },
      { key: "flex_booking_pending", label: "Flex class — waiting for confirmation", audience: "Members", when: "When a member books a flex class that still needs confirming", feature: "flex" },
      { key: "flex_booking_confirmed", label: "Flex class — going ahead", audience: "Members", when: "When a flex class is confirmed to run", feature: "flex" },
      { key: "flex_booking_not_confirmed", label: "Flex class — not confirmed", audience: "Members", when: "When a flex class is not confirmed by the cut-off and the credit is returned", feature: "flex" },
      { key: "class_restored", label: "Flex class — back on after all", audience: "Members", when: "When the studio runs a class cancelled at its cut-off anyway", feature: "flex" },
      { key: "flex_rescue_2days", label: "Flex rescue — 2 days before", audience: "Members", when: "2 days before a flex class still under its minimum, offering a move to a core class", feature: "flex" },
      { key: "flex_rescue_final", label: "Flex rescue — last call", audience: "Members", when: "A few hours before the flex cut-off, a last offer to move to a core class", feature: "flex" },
      { key: "waitlist_offer", label: "A waitlist seat is yours", audience: "Members", when: "When a seat opens and the member is next on the waitlist" },
      { key: "waitlist_missed", label: "Didn't get a waitlist seat", audience: "Members", when: "When a waitlist offer expires without being claimed" },
      { key: "walk_in_welcome", label: "Walk-in welcome", audience: "Members", when: "When an instructor adds a new member as a walk-in" },
      { key: "credit_returned_by_studio", label: "Credit returned after a late cancel", audience: "Members", when: "When staff return the credit or free class a late cancellation used" },
      { key: "booking_cancelled_committed", label: "A member cancelled a confirmed class", audience: "Instructors", when: "When a member cancels out of a class that is already confirmed to run", feature: "guarantees" },
      { key: "class_restored_coach", label: "A cancelled class is back on", audience: "Instructors", when: "When the studio runs a class cancelled at its cut-off anyway", feature: "flex" },
      { key: "booking_rebooked", label: "Booking moved to another class", audience: "Members", when: "When staff move a member's booking to another class" },
      { key: "booking_removed_by_studio", label: "Taken off a class", audience: "Members", when: "When staff take a member off a class" },
      { key: "hold_released_by_studio", label: "Held seat released", audience: "Members", when: "When staff release a seat a member was holding" },
      { key: "free_class_duplicate", label: "Free class already had", audience: "Members", when: "When a free class is held because the same person has already had one", feature: "free_first" },
      { key: "free_reservation_due", label: "Free class: reservation fee due", audience: "Members", when: "When a free seat needs the reservation fee to be kept", feature: "free_first" },
      { key: "free_reservation_released", label: "Free class: seat released", audience: "Members", when: "When an unpaid free seat is released at the cut-off", feature: "free_first" },
      { key: "free_reservation_lost_seat", label: "Free class: fee became credit", audience: "Members", when: "When a reservation fee is paid after the seat went and the class is full", feature: "free_first" },
      { key: "free_reservation_returned", label: "Free class: reservation fee returned", audience: "Members", when: "When the studio returns a reservation fee", feature: "free_first" },
    ],
  },
  {
    title: "Classes",
    keys: [
      { key: "class_reminder", label: "Class reminder", audience: "Members", when: "The day before a booked class" },
      { key: "class_cancelled", label: "Class cancelled", audience: "Members", when: "When the studio cancels a class they are booked into" },
      { key: "class_moved", label: "Class moved", audience: "Members", when: "When a booked class changes time, room or instructor" },
      { key: "peak_cancel_window", label: "Free cancellation window closing", audience: "Members", when: "Shortly before the free cancellation window closes on a peak booking" },
      { key: "day_tier_flex", label: "A class changed to flex", audience: "Members", when: "When the studio changes a booked class to flex for the day", feature: "flex" },
    ],
  },
  {
    title: "Plans and credits",
    keys: [
      { key: "membership_expiring", label: "Membership expiring", audience: "Members", when: "Before a plan ends, when the keep sequence is off" },
      { key: "membership_ended", label: "Membership ended", audience: "Members", when: "When a plan ends" },
      { key: "membership_frozen", label: "Membership frozen", audience: "Members", when: "When the studio pauses a plan" },
      { key: "credit_expiry", label: "Credits expiring", audience: "Members", when: "A week before classes on a pack expire, when the keep sequence is off" },
      { key: "product_order_paid", label: "Shop order paid", audience: "Members", when: "When a shop order is paid and ready to collect", feature: "shop" },
      { key: "plan_waiting_claim", label: "Plan bought, set up your account", audience: "Members", when: "When somebody without an account pays for a plan" },
      { key: "plan_claim_reminder", label: "Plan still waiting", audience: "Members", when: "2 and 7 days after paying, if the account is not set up yet" },
      { key: "plan_in_account", label: "Plan in your account", audience: "Members", when: "When somebody with an account buys on the website without signing in" },
      { key: "checkout_rescue_plan", label: "Checkout rescue: plan", audience: "Members", when: "An hour after a plan, pack or membership checkout expires without payment" },
      { key: "checkout_rescue_gift", label: "Checkout rescue: gift card", audience: "Members", when: "An hour after a gift card checkout expires without payment" },
      { key: "checkout_rescue_shop", label: "Checkout rescue: shop order", audience: "Members", when: "An hour after a shop checkout expires without payment", feature: "shop" },
      { key: "checkout_rescue_reservation", label: "Checkout rescue: free class reservation", audience: "Members", when: "An hour after a free class reservation fee checkout expires without payment", feature: "free_first" },
      { key: "checkout_rescue_private", label: "Checkout rescue: private session", audience: "Members", when: "An hour after a private session checkout expires or fails without payment" },
      { key: "intro_offer_refunded", label: "Intro offer refunded", audience: "Members", when: "When an intro offer bought on the website goes to somebody who has had theirs" },
      { key: "payment_failed", label: "Card payment failed", audience: "Members", when: "When a card payment for a plan fails" },
      { key: "payment_refunded", label: "Payment refunded", audience: "Members", when: "When the studio refunds a payment" },
      { key: "xendit_purchase_failed", label: "Online payment did not go through", audience: "Members", when: "When an online payment fails or expires" },
    ],
  },
  {
    title: "Account",
    keys: [
      { key: "member_invite", label: "Member invite", audience: "Members", when: "When the studio invites someone to join" },
      { key: "account_deleted", label: "Account deleted", audience: "Members", when: "When a member deletes their account" },
      { key: "milestone", label: "A milestone reached", audience: "Members", when: "When a member reaches a class milestone" },
      { key: "announcement_posted", label: "Studio announcement", audience: "Members", when: "When the studio posts an announcement" },
      { key: "guest_invite", label: "Guest invite", audience: "Members", when: "When a member invites a guest with a guest pass", feature: "guest_passes" },
      { key: "guest_host_cancelled", label: "Guest's host cancelled", audience: "Members", when: "When the host of a guest pass cancels", feature: "guest_passes" },
      { key: "guest_waiver_reminder", label: "Guest waiver reminder", audience: "Members", when: "When an invited guest has not signed the waiver", feature: "guest_passes" },
      { key: "staff_invite", label: "Staff invite", audience: "Staff", when: "When the owner or a manager invites a manager or front desk" },
      { key: "instructor_invite", label: "Instructor invite", audience: "Instructors", when: "When the studio invites an instructor to the app" },
      { key: "guest_waiver_host_nudge", label: "Your guest still needs to sign", audience: "Members", when: "A few hours before class, to a member whose guest has not signed the waiver", feature: "guest_passes" },
    ],
  },
  {
    title: "Convert — a new member's first days",
    keys: [
      { key: "convert_before_class", label: "Before their first class", audience: "Members", when: "The day before a first-timer's free class", feature: "free_first" },
      { key: "convert_after_class", label: "After their first class", audience: "Members", when: "The day after a first-timer's free class", feature: "free_first" },
      { key: "convert_day3", label: "Day 3 nudge", audience: "Members", when: "3 days after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_day7", label: "Day 7 nudge", audience: "Members", when: "7 days after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_last_day", label: "Last day of the intro offer", audience: "Members", when: "The last day of the intro offer, if no plan bought", feature: "free_first" },
      { key: "convert_missed_you", label: "Missed-you note", audience: "Members", when: "The morning after a first-timer misses their free class", feature: "free_first" },
      { key: "convert_book_first", label: "Signed up, never booked", audience: "Members", when: "1 and 7 days after signing up with nothing booked", feature: "free_first" },
      { key: "convert_week_2", label: "Week 2 nudge", audience: "Members", when: "2 weeks after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_week_3", label: "Week 3 nudge", audience: "Members", when: "3 weeks after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_week_4", label: "Week 4 nudge", audience: "Members", when: "4 weeks after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_week_5", label: "Week 5 nudge", audience: "Members", when: "5 weeks after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_week_6", label: "Week 6 nudge", audience: "Members", when: "6 weeks after the free class, if no plan bought", feature: "free_first" },
      { key: "convert_monthly", label: "Monthly check-in", audience: "Members", when: "Monthly after the convert weeks, if no plan bought", feature: "free_first" },
    ],
  },
  {
    title: "Keep — renewals, credits, win-backs",
    keys: [
      { key: "keep_renew_7", label: "Plan ends in a week", audience: "Members", when: "A week before a plan ends" },
      { key: "keep_renew_1", label: "Plan ends tomorrow", audience: "Members", when: "The day before a plan ends" },
      { key: "keep_renew_0", label: "Plan ends today", audience: "Members", when: "The day a plan ends" },
      { key: "keep_lapsed_3", label: "Lapsed 3 days ago", audience: "Members", when: "3 days after a plan ended with no renewal" },
      { key: "keep_credits_7", label: "Credits expire in a week", audience: "Members", when: "A week before pack classes expire" },
      { key: "keep_credits_2", label: "Credits expire in 2 days", audience: "Members", when: "2 days before pack classes expire" },
      { key: "keep_winback_30", label: "Win-back at 30 days", audience: "Members", when: "30 days after the last class" },
      { key: "keep_winback_60", label: "Win-back at 60 days", audience: "Members", when: "60 days after the last class" },
      { key: "keep_drifting", label: "Drifting — a gentle check-in", audience: "Members", when: "When a member's attendance drops into drifting" },
    ],
  },
  {
    title: "Retention tasks — the message you copy",
    keys: [
      { key: "task_unconverted_message", label: "Not-yet-converted reach-out", audience: "Staff", when: "Copied into a message when a first-timer has not bought a plan" },
      { key: "task_at_risk_message", label: "At-risk reach-out", audience: "Staff", when: "Copied into a message when a member is at risk" },
    ],
  },
  {
    title: "Retention — the email you send from the board",
    keys: [
      { key: "retention_unconverted", label: "Not yet converted", audience: "Members", when: "Sent by hand from the Retention board" },
      { key: "retention_at_risk", label: "At risk", audience: "Members", when: "Sent by hand from the Retention board" },
      { key: "retention_drifting", label: "Drifting", audience: "Members", when: "Sent by hand from the Retention board" },
      { key: "retention_expiring", label: "Membership expiring", audience: "Members", when: "Sent by hand from the Retention board" },
      { key: "retention_lapsed", label: "Lapsed — win-back", audience: "Members", when: "Sent by hand from the Retention board" },
      { key: "retention", label: "Retention email frame", audience: "Members", when: "The frame around a message sent from the Retention board" },
    ],
  },
  {
    title: "Closures",
    keys: [
      { key: "studio_closure_notice", label: "Studio closure notice", audience: "Members", when: "Sent by hand when the studio closes for a period" },
      { key: "instructor_closure_notice", label: "Instructor closure digest", audience: "Instructors", when: "One digest per instructor when the studio closes for a period" },
    ],
  },
  {
    title: "Messages",
    keys: [
      { key: "message_to_member", label: "The studio replied to a member", audience: "Members", when: "When staff reply to a member's message", feature: "messages" },
      { key: "message_to_studio", label: "A member messaged the studio", audience: "Staff", when: "When a member sends a message to the studio", feature: "messages" },
      { key: "staff_message", label: "A message from the studio", audience: "Members", when: "When staff send a member a message from their profile" },
    ],
  },
  {
    title: "Instructors",
    keys: [
      { key: "instructor_daily_digest", label: "Your classes for the day", audience: "Instructors", when: "At each day's cut-off: the classes going ahead and the ones cancelled for want of bookings" },
      { key: "instructor_assigned", label: "Class assigned to you", audience: "Instructors", when: "When the studio assigns you a class" },
      { key: "instructor_week_ahead", label: "Your week ahead", audience: "Instructors", when: "Sunday evening, your classes for the week, when class reminders are on" },
      { key: "instructor_tomorrow", label: "Teaching tomorrow", audience: "Instructors", when: "The evening before a day you teach, when class reminders are on" },
      { key: "instructor_class_cancelled", label: "A class of yours was cancelled", audience: "Instructors", when: "When the studio cancels a class you teach for a studio, instructor or force-majeure reason" },
      { key: "cover_available", label: "A class needs cover", audience: "Instructors", when: "When a class needs cover and you can take it" },
      { key: "availability_due", label: "Availability due", audience: "Instructors", when: "When your availability for next month is due" },
      { key: "month_roster", label: "Next month's schedule (confirm)", audience: "Instructors", when: "When the studio publishes next month's schedule and asks you to confirm" },
      { key: "month_roster_plain", label: "Next month's schedule", audience: "Instructors", when: "When the studio publishes next month's schedule" },
      { key: "instructor_class_ended_unmarked", label: "Class ended — bookings still unmarked", audience: "Instructors", when: "After a class ends with bookings not checked in" },
      { key: "instructor_time_off", label: "An instructor blocked off dates", audience: "Staff", when: "When an instructor marks time off that contains classes they teach" },
      { key: "booking_for_instructor", label: "Someone booked your class", audience: "Instructors", when: "When a member books a class you teach, if you asked to be told" },
      { key: "instructor_booking_alert", label: "Bookings changed on your class", audience: "Instructors", when: "At most every 15 minutes, when bookings on your class change, if the studio turns alerts on" },
      { key: "instructor_substituted", label: "You are covering a class", audience: "Instructors", when: "When the studio puts you on a class in someone else's place" },
      { key: "instructor_unmarked_bookings", label: "Bookings left unmarked", audience: "Instructors", when: "The morning after a class with bookings nobody checked in" },
      { key: "instructor_unconfirmed", label: "Classes still to confirm", audience: "Staff", when: "When instructors have not confirmed this week's classes" },
      { key: "core_committed", label: "Your class is going ahead", audience: "Instructors", when: "When a core class reaches its minimum early", feature: "guarantees" },
      { key: "flex_going_ahead", label: "Your flex class is going ahead", audience: "Instructors", when: "When a flex class reaches its minimum", feature: "flex" },
      { key: "commitment_digest", label: "Classes decided at the cut-off", audience: "Instructors", when: "After a cut-off decides several of your classes", feature: "guarantees" },
      { key: "class_reassigned_off", label: "Taken off a class", audience: "Instructors", when: "When the studio gives a class you teach to someone else" },
      { key: "instructor_archived", label: "An instructor was archived", audience: "Staff", when: "When an instructor is archived and their classes need someone" },
      { key: "assignment_confirmation_request", label: "Please confirm your classes", audience: "Instructors", when: "When the studio assigns you classes and asks you to confirm" },
      { key: "week_confirm_ask", label: "Confirm next week", audience: "Instructors", when: "On the studio's ask day, for next week's classes" },
      { key: "week_confirm_reminder", label: "Reminder: confirm next week", audience: "Instructors", when: "On the studio's reminder day, if next week is still unconfirmed" },
      { key: "week_unconfirmed", label: "Classes not confirmed", audience: "Staff", when: "On the studio's escalation day, the classes still unconfirmed" },
    ],
  },
  {
    title: "Cover and shifts",
    keys: [
      { key: "cover_requested", label: "Cover asked for", audience: "Staff", when: "When an instructor asks for cover on a class" },
      { key: "cover_urgent", label: "Urgent cover needed", audience: "Staff", when: "When a cover request is close to the class or unanswered" },
      { key: "cover_needs_approval", label: "A cover needs your approval", audience: "Staff", when: "When a colleague agrees to cover and the studio approves covers" },
      { key: "cover_approved", label: "Cover approved", audience: "Instructors", when: "When the studio approves a cover you asked for or took" },
      { key: "cover_declined", label: "Cover request declined", audience: "Instructors", when: "When the studio declines your cover request" },
      { key: "cover_auto_covered", label: "Your class was covered", audience: "Instructors", when: "When a colleague takes your class and the studio accepts covers automatically" },
      { key: "cover_asked", label: "A colleague asked you to cover", audience: "Instructors", when: "When a colleague asks you by name to cover their class" },
      { key: "cover_asked_confirmed", label: "Your colleague will cover", audience: "Instructors", when: "When the colleague you asked agrees to cover" },
      { key: "cover_asked_declined", label: "Your colleague can't cover", audience: "Instructors", when: "When the colleague you asked says no or does not answer in time" },
      { key: "cover_colleague_declined", label: "Cover now open to everyone", audience: "Instructors", when: "When the colleague you asked can't, so the class opens to everyone" },
      { key: "open_shifts_available", label: "Open classes to take", audience: "Instructors", when: "When there are classes with no instructor you could teach" },
      { key: "shift_application_received", label: "Someone wants an open class", audience: "Staff", when: "When an instructor asks to take an open class" },
      { key: "shift_approved", label: "You got the class", audience: "Instructors", when: "When the studio gives you an open class you asked for" },
      { key: "shift_declined", label: "Not this time", audience: "Instructors", when: "When the studio gives an open class you asked for to someone else" },
      { key: "shift_withdrawn", label: "An instructor pulled out", audience: "Staff", when: "When an instructor withdraws from an open class they asked for" },
      { key: "shift_taken_off", label: "Taken off a class", audience: "Instructors", when: "When the studio opens a class you were teaching as an open shift" },
    ],
  },
  {
    title: "Availability",
    keys: [
      { key: "availability_approved", label: "Availability approved", audience: "Instructors", when: "When the studio approves your availability" },
      { key: "availability_changes_requested", label: "Availability: changes asked for", audience: "Instructors", when: "When the studio sends your availability back with a note" },
      { key: "availability_edited_by_studio", label: "Your availability was edited", audience: "Instructors", when: "When the studio changes the hours you sent" },
      { key: "availability_narrowed_instructor", label: "Your hours no longer cover a class", audience: "Instructors", when: "When your new hours leave a class of yours uncovered" },
      { key: "availability_narrowed_staff", label: "An instructor's hours changed", audience: "Staff", when: "When an instructor's new hours leave classes uncovered" },
    ],
  },
  {
    title: "Private sessions",
    keys: [
      { key: "private_confirmed", label: "Private session booked", audience: "Members", when: "When a private session is paid and confirmed" },
      { key: "private_moved", label: "Private session moved", audience: "Members", when: "When a private session is moved to a new time" },
      { key: "private_cancelled", label: "Private session cancelled", audience: "Members", when: "When a member cancels a private session" },
      { key: "private_studio_cancelled", label: "Private session cancelled by the studio", audience: "Members", when: "When the studio cancels a private session" },
      { key: "private_time_taken", label: "That private session time was taken", audience: "Members", when: "When the time was taken before the payment came through" },
      { key: "private_booked", label: "A private session with you", audience: "Instructors", when: "When a member books or moves a private session with you" },
    ],
  },
  {
    title: "Gift cards",
    keys: [
      { key: "gift_card_sent", label: "A gift card for you", audience: "Members", when: "To the person a gift card is for, on the delivery day" },
      { key: "gift_card_receipt", label: "Gift card receipt", audience: "Members", when: "To the buyer when a gift card is paid" },
      { key: "gift_card_redeemed", label: "Gift card redeemed", audience: "Members", when: "To the buyer when the gift card is redeemed" },
    ],
  },
  {
    title: "Challenges",
    keys: [
      { key: "challenge_opening", label: "A challenge opens", audience: "Members", when: "When a challenge opens to join", feature: "challenges" },
      { key: "challenge_joined", label: "You joined a challenge", audience: "Members", when: "When a member joins a challenge", feature: "challenges" },
      { key: "challenge_milestone", label: "Challenge milestone", audience: "Members", when: "When a member reaches a milestone in a challenge", feature: "challenges" },
      { key: "challenge_ending_soon", label: "Challenge ending soon", audience: "Members", when: "A few days before a challenge ends", feature: "challenges" },
      { key: "challenge_completed", label: "Challenge completed", audience: "Members", when: "When a member completes a challenge", feature: "challenges" },
    ],
  },
  {
    title: "Campaigns",
    keys: [
      { key: "campaign", label: "Campaign email frame", audience: "Members", when: "The frame around every campaign you send" },
      { key: "campaign_free_waiting", label: "Campaign: your free class is waiting", audience: "Members", when: "The weekly campaign to members who have not used their free class" },
      { key: "campaign_try_format", label: "Campaign: try a class format", audience: "Members", when: "The weekly campaign suggesting a class format" },
    ],
  },
  {
    title: "Studio and billing",
    keys: [
      { key: "owner_daily_check", label: "Daily money check", audience: "Staff", when: "Each morning, when the daily check finds something to look at" },
      { key: "platform_billing_warning", label: "Studiior billing warning", audience: "Staff", when: "When the studio's Studiior subscription needs attention" },
    ],
  },
];

const EDITABLE = new Set(TEMPLATE_GROUPS.flatMap((g) => g.keys.map((k) => k.key)));
const BY_KEY = new Map(TEMPLATE_GROUPS.flatMap((g) => g.keys.map((k) => [k.key, k])));

/** True when a key is one of the composer-editable templates. */
export function isEditableTemplate(key) {
  return EDITABLE.has(key);
}

/** The full entry for a key (label, audience, when, feature), or null. */
export function templateEntry(key) {
  return BY_KEY.get(key) ?? null;
}

/** Label for a key, or the key itself if unknown. */
export function templateLabel(key) {
  return BY_KEY.get(key)?.label ?? key;
}

/** The feature a key belongs to, or null when it is always relevant. A key with
 *  a feature is hidden from the Templates list and the per-email lists while that
 *  feature is off — not deleted, its switch untouched; it returns when the
 *  feature is turned on. */
export function templateFeature(key) {
  return BY_KEY.get(key)?.feature ?? null;
}

/** Is a key visible given the set of features the studio has ON? A key with no
 *  feature is always visible; a feature key is visible only when its feature is
 *  in the set. `features` is a Set of feature ids ("flex", "free_first",
 *  "guest_passes", "challenges", "shop", "guarantees"). */
export function isTemplateVisible(key, features) {
  const f = templateFeature(key);
  return f === null || features.has(f);
}

/** Build the set of feature ids a studio has ON, from its flags, so a page can
 *  pass it to isTemplateVisible. Shop is "has any products", not a flag. */
export function featureSet({ flex, freeFirst, guest, challenges, shop, guarantees, messages }) {
  const s = new Set();
  if (flex) s.add("flex");
  if (freeFirst) s.add("free_first");
  if (guest) s.add("guest_passes");
  if (challenges) s.add("challenges");
  if (shop) s.add("shop");
  if (guarantees) s.add("guarantees");
  if (messages) s.add("messages");
  return s;
}

/** The emails a master switch governs, for the per-email on/off list beneath it.
 *  "convert" → the convert_* keys, "keep" → the keep_* keys — read from the
 *  groups so the list and the Templates page can never disagree. */
export function templateKeysForMaster(master) {
  const title = master === "convert" ? "Convert" : master === "keep" ? "Keep" : null;
  if (!title) return [];
  const g = TEMPLATE_GROUPS.find((x) => x.title.startsWith(title));
  return g ? g.keys : [];
}

/** Unique {placeholder} names across subject + body, in first-seen order. */
/** Decision 80 note: tokens every email can use beside its own, plus the
 *  roster table in the month roster emails. */
export function globalTokens(key) {
  const t = ["flex_min", "flex_cutoff"];
  if (key === "month_roster" || key === "month_roster_plain") t.push("roster_table");
  return t;
}

export function placeholdersFrom(...texts) {
  const seen = [];
  const re = /\{([a-z0-9_]+)\}/gi;
  for (const t of texts) {
    if (!t) continue;
    let m;
    while ((m = re.exec(t))) if (!seen.includes(m[1])) seen.push(m[1]);
  }
  return seen;
}
