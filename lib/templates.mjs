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
      { key: "flex_booking_pending", label: "Flex class — waiting for confirmation", audience: "Members", when: "When a member books a flex class that still needs confirming", feature: "flex" },
      { key: "flex_booking_confirmed", label: "Flex class — going ahead", audience: "Members", when: "When a flex class is confirmed to run", feature: "flex" },
      { key: "flex_booking_not_confirmed", label: "Flex class — not confirmed", audience: "Members", when: "When a flex class is not confirmed by the cut-off and the credit is returned", feature: "flex" },
      { key: "waitlist_offer", label: "A waitlist seat is yours", audience: "Members", when: "When a seat opens and the member is next on the waitlist" },
      { key: "waitlist_missed", label: "Didn't get a waitlist seat", audience: "Members", when: "When a waitlist offer expires without being claimed" },
      { key: "walk_in_welcome", label: "Walk-in welcome", audience: "Members", when: "When an instructor adds a new member as a walk-in" },
      { key: "booking_cancelled_committed", label: "A member cancelled a confirmed class", audience: "Instructors", when: "When a member cancels out of a class that is already confirmed to run", feature: "guarantees" },
    ],
  },
  {
    title: "Classes",
    keys: [
      { key: "class_reminder", label: "Class reminder", audience: "Members", when: "The day before a booked class" },
      { key: "class_cancelled", label: "Class cancelled", audience: "Members", when: "When the studio cancels a class they are booked into" },
      { key: "class_moved", label: "Class moved", audience: "Members", when: "When a booked class changes time, room or instructor" },
      { key: "peak_cancel_window", label: "Free cancellation window closing", audience: "Members", when: "Shortly before the free cancellation window closes on a peak booking" },
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
    ],
  },
  {
    title: "Closures",
    keys: [
      { key: "studio_closure_notice", label: "Studio closure notice", audience: "Members", when: "Sent by hand when the studio closes for a period" },
    ],
  },
  {
    title: "Instructors",
    keys: [
      { key: "instructor_assigned", label: "Class assigned to you", audience: "Instructors", when: "When the studio assigns you a class" },
      { key: "instructor_week_ahead", label: "Your week ahead", audience: "Instructors", when: "Sunday evening, your classes for the week, when class reminders are on" },
      { key: "instructor_tomorrow", label: "Teaching tomorrow", audience: "Instructors", when: "The evening before a day you teach, when class reminders are on" },
      { key: "instructor_class_cancelled", label: "A class of yours was cancelled", audience: "Instructors", when: "When the studio cancels a class you teach" },
      { key: "core_committed", label: "Your class is confirmed to run", audience: "Instructors", when: "When a class you teach reaches its minimum and is confirmed to run", feature: "guarantees" },
      { key: "cover_available", label: "A class needs cover", audience: "Instructors", when: "When a class needs cover and you can take it" },
      { key: "availability_due", label: "Availability due", audience: "Instructors", when: "When your availability for next month is due" },
      { key: "month_roster", label: "Next month's schedule (confirm)", audience: "Instructors", when: "When the studio publishes next month's schedule and asks you to confirm" },
      { key: "month_roster_plain", label: "Next month's schedule", audience: "Instructors", when: "When the studio publishes next month's schedule" },
      { key: "instructor_class_ended_unmarked", label: "Class ended — bookings still unmarked", audience: "Instructors", when: "After a class ends with bookings not checked in" },
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
export function featureSet({ flex, freeFirst, guest, challenges, shop, guarantees }) {
  const s = new Set();
  if (flex) s.add("flex");
  if (freeFirst) s.add("free_first");
  if (guest) s.add("guest_passes");
  if (challenges) s.add("challenges");
  if (shop) s.add("shop");
  if (guarantees) s.add("guarantees");
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
