// Decision 71 — the one list of every studio setting.
//
// Pure, no imports. It drives three things that used to drift apart: the
// Settings home search box, the headed sections on each of the six group
// pages, and `scripts/audit-settings-ui.py` rule 3 (a studio_settings/plans
// column with a write path that is not named here fails the audit).
//
// An entry names the DB column(s) it edits in `columns` so the audit can match
// it; a standalone entry carries the route it lives on. Labels are the
// plain-language ones from the Decision 71 inventory; `synonyms` are what a
// studio owner might actually type (gcash → Xendit, qr → check-in code).

/** @type {import('./settings-registry').SettingGroup[]} */
export const GROUPS = [
  { id: "studio", label: "Studio", route: "/settings/studio",
    description: "Your studio’s name, hours, location and check-in code.",
    sections: [
      { anchor: "identity", title: "Studio details", summary: "Your studio’s name; member app address, time zone, currency and country" },
      { anchor: "team", title: "Team", summary: "Invite managers and front desk, change roles, remove access" },
      { anchor: "opening-hours", title: "Opening hours", summary: "The one daily open–close window (optional)" },
      { anchor: "location", title: "Location & self check-in", summary: "Coordinates and the geofence for phone check-in" },
      { anchor: "checkin-code", title: "Check-in code", summary: "The printable QR for the wall" },
      { anchor: "closures", title: "Closures", summary: "Days you’re shut — classes cancelled, members told" },
    ] },
  { id: "booking", label: "Booking & cancellation", route: "/settings/booking",
    description: "How and how far ahead members book, cancel, check in — and which classes run.",
    sections: [
      { anchor: "booking-rules", title: "Booking & cancellation rules", summary: "Booking window, cancellation cut-off, check-in window, waiver, late-cancel credit" },
      { anchor: "publication", title: "Publishing the month", summary: "Keep each month a draft until you publish it" },
      { anchor: "peak", title: "Peak hours", summary: "Mark busy hours and limit them on unlimited plans" },
      { anchor: "fair-use", title: "Repeated late cancellations", summary: "Suspend repeat offenders, and the free-cancellation reminder" },
      { anchor: "hide-unstaffed", title: "Unstaffed classes", summary: "Hide classes with no instructor from members" },
      { anchor: "horizon", title: "How far ahead classes are generated", summary: "The rolling horizon the timetable is built to" },
      { anchor: "waiver", title: "Waiver document", summary: "Publish the waiver members sign" },
    ] },
  { id: "classes", label: "Classes & instructors", route: "/settings/classes",
    description: "Guarantees, flex, how classes get staffed, cover, and what instructors are asked.",
    sections: [
      { anchor: "core", title: "Guarantees & flex", summary: "When a class runs regardless, or only if enough book — and what it owes" },
      { anchor: "staffing", title: "How classes get staffed", summary: "Auto-assign, require availability, or let instructors claim" },
      { anchor: "cover", title: "Cover", summary: "Let urgent cover be taken without approval" },
      { anchor: "availability", title: "Availability & confirmations", summary: "When the month is due, reminders, and week confirmations" },
      { anchor: "carry-forward", title: "Carry-forward", summary: "Carry a silent instructor’s roster forward" },
      { anchor: "booking-alerts", title: "Booking alerts", summary: "Email instructors about bookings on their classes" },
      { anchor: "assignment-confirmations", title: "Assignment confirmations", summary: "Ask instructors to confirm classes you assign them" },
      { anchor: "class-reminders", title: "Class reminders", summary: "Email instructors their week ahead and the day before" },
    ] },
  { id: "memberships", label: "Memberships & payments", route: "/settings/memberships",
    description: "Plans, instructor pay, bonuses, free first classes and guests.",
    sections: [
      { anchor: "pay-schedule", title: "Instructor pay", summary: "How often instructors are paid, and the payment date" },
      { anchor: "conversion", title: "Conversion bonus", summary: "Reward the instructor of a member’s first class" },
      { anchor: "seat-caps", title: "Places on a plan", summary: "Limit how many members hold a plan" },
      { anchor: "how-to-buy", title: "How members buy", summary: "The words shown under your plans in the member app" },
      { anchor: "free-first", title: "First class free", summary: "A new member’s first class free, and its limits" },
      { anchor: "guest-passes", title: "Guest passes", summary: "Let a member bring a guest for a free first class" },
      { anchor: "challenges", title: "Challenges", summary: "Run attendance goals and streaks for members" },
      { anchor: "plans", title: "Membership plans", summary: "Create and edit the plans members buy" },
    ] },
  { id: "communications", label: "Communications", route: "/settings/communications",
    description: "What members see — your app’s look, names, times, and how they reach you.",
    sections: [
      { anchor: "member-app", title: "Member app look & contact", summary: "Colours, logo, photo, names, time format and your contact details" },
      { anchor: "campaign", title: "Campaign sending domain", summary: "The domain your marketing emails send from" },
    ] },
  { id: "integrations", label: "Apps & integrations", route: "/settings/integrations",
    description: "Take online payments, and publish your studio’s app to the stores.",
    sections: [
      { anchor: "stripe", title: "Card payments (Stripe)", summary: "Take card payments online (owner only)" },
      { anchor: "xendit", title: "Xendit", summary: "Online payments in the Philippines (owner only)" },
      { anchor: "store-apps", title: "Store apps", summary: "Android & iPhone app-store verification" },
    ] },
];

/** @type {import('./settings-registry').SettingEntry[]} */
export const SETTINGS = [
  // ---- Studio ----------------------------------------------------------------
  { id: "studio-name", group: "studio", label: "Studio name",
    synonyms: ["name", "title", "business name"],
    page: "/settings/studio", anchor: "identity" },
  { id: "member-app-address", group: "studio", label: "Member app address",
    synonyms: ["web address", "subdomain", "url", "link"],
    page: "/settings/studio", anchor: "identity" },
  { id: "time-zone", group: "studio", label: "Time zone",
    synonyms: ["timezone", "region", "clock"],
    page: "/settings/studio", anchor: "identity" },
  { id: "currency", group: "studio", label: "Currency",
    synonyms: ["money", "price currency"],
    page: "/settings/studio", anchor: "identity" },
  { id: "country", group: "studio", label: "Country",
    synonyms: ["region", "locale"],
    page: "/settings/studio", anchor: "identity" },
  { id: "opening-hours", group: "studio", label: "Opening hours",
    synonyms: ["hours", "open", "close"],
    page: "/settings/studio", anchor: "opening-hours", columns: ["open_time", "close_time"] },
  { id: "self-checkin-location", group: "studio", label: "Studio location & self check-in",
    synonyms: ["address", "map", "geofence", "gps"],
    page: "/settings/studio", anchor: "location" },
  { id: "team", group: "studio", label: "Team",
    synonyms: ["staff", "manager", "front desk", "invite"],
    page: "/settings/studio", anchor: "team", standalone: "/settings/team" },
  { id: "checkin-code", group: "studio", label: "Printable check-in code",
    synonyms: ["qr", "scan", "door code"],
    page: "/settings/studio", anchor: "checkin-code", standalone: "/settings/studio/checkin-code/print" },
  { id: "closures", group: "studio", label: "Closures & holidays",
    synonyms: ["closed", "holiday", "break", "shut"],
    page: "/settings/studio", anchor: "closures", standalone: "/settings/closures" },

  // ---- Booking & cancellation ------------------------------------------------
  { id: "booking-window", group: "booking", label: "How far ahead members can book",
    synonyms: ["booking window", "advance booking", "how early"],
    page: "/settings/booking", anchor: "booking-rules", columns: ["booking_window_days"] },
  { id: "cancellation-cutoff", group: "booking", label: "Cancellation cut-off",
    synonyms: ["cancel deadline", "notice", "late cancel"],
    page: "/settings/booking", anchor: "booking-rules", columns: ["cancellation_cutoff_minutes"] },
  { id: "late-cancel-credit", group: "booking", label: "Late cancellation uses the credit",
    synonyms: ["penalty", "forfeit", "charge"],
    page: "/settings/booking", anchor: "booking-rules", columns: ["late_cancel_consumes_credit"] },
  { id: "checkin-window", group: "booking", label: "Check-in window",
    synonyms: ["check in", "arrive", "door open"],
    page: "/settings/booking", anchor: "booking-rules",
    columns: ["checkin_opens_minutes_before", "checkin_closes_minutes_after"] },
  { id: "require-waiver", group: "booking", label: "Require a signed waiver",
    synonyms: ["waiver", "consent", "sign"],
    page: "/settings/booking", anchor: "booking-rules", columns: ["require_waiver"] },
  { id: "publish-month", group: "booking", label: "Publish the month",
    synonyms: ["draft", "release", "go live"],
    page: "/settings/booking", anchor: "publication", columns: ["publication_enabled"] },
  { id: "peak-hours", group: "booking", label: "Peak hours & limits",
    synonyms: ["busy hours", "rush", "fair use", "peak"],
    page: "/settings/booking", anchor: "peak", columns: ["peak_allowance_enabled"] },
  { id: "repeated-late-cancellations", group: "booking", label: "Repeated late cancellations",
    synonyms: ["no-shows", "strikes", "suspend", "ban"],
    page: "/settings/booking", anchor: "fair-use",
    columns: ["suspension_enabled", "suspension_window_days", "suspension_warn_at",
      "suspension_at", "suspension_days", "suspension_repeat_days"] },
  { id: "free-cancel-reminder", group: "booking", label: "Free-cancellation reminder",
    synonyms: ["reminder", "nudge", "peak reminder"],
    page: "/settings/booking", anchor: "fair-use", columns: ["peak_cutoff_reminder_minutes"] },
  { id: "hide-unstaffed", group: "booking", label: "Hide classes with no instructor",
    synonyms: ["unstaffed", "hide", "no coach"],
    page: "/settings/booking", anchor: "hide-unstaffed", columns: ["hide_unstaffed_from_members"] },
  { id: "timetable-horizon", group: "booking", label: "How far ahead classes are generated",
    synonyms: ["horizon", "generate ahead", "schedule ahead"],
    page: "/settings/booking", anchor: "horizon", standalone: "/settings/horizon",
    columns: ["occurrence_horizon_days"] },
  { id: "waiver-document", group: "booking", label: "Waiver document",
    synonyms: ["waiver", "liability", "agreement", "pdf"],
    page: "/settings/booking", anchor: "waiver", standalone: "/settings/waiver" },

  // ---- Classes & instructors -------------------------------------------------
  { id: "core-classes", group: "classes", label: "Core classes (minimum to run)",
    synonyms: ["minimum", "runs if", "holding pay", "guarantee"],
    page: "/settings/classes", anchor: "core",
    columns: ["guarantees_enabled", "core_min_bookings", "core_cutoff_hours",
      "core_unmet_pay_pct", "core_unmet_pay_cents", "adjacency_minutes"] },
  { id: "flex-classes", group: "classes", label: "Flex classes",
    synonyms: ["flexible", "run if enough", "maybe class"],
    page: "/settings/classes", anchor: "core",
    columns: ["flex_enabled", "flex_min_bookings", "flex_deadline_mode", "flex_deadline_time",
      "flex_deadline_hours", "flex_unmet_pay_cents", "flex_standby_pay_cents"] },
  { id: "auto-assign", group: "classes", label: "Assign instructors automatically",
    synonyms: ["auto-assign", "staffing", "fill"],
    page: "/settings/classes", anchor: "staffing", columns: ["auto_assign_open_classes"] },
  { id: "require-availability", group: "classes", label: "Only assign inside stated availability",
    synonyms: ["availability", "can’t teach", "unavailable"],
    page: "/settings/classes", anchor: "staffing", columns: ["assign_requires_availability"] },
  { id: "claiming", group: "classes", label: "Instructors claim their classes",
    synonyms: ["claim", "pick up", "open classes"],
    page: "/settings/classes", anchor: "staffing",
    columns: ["claiming_enabled", "core_claim_default_cap"] },
  { id: "cover", group: "classes", label: "Urgent cover without approval",
    synonyms: ["cover", "substitute", "fill in"],
    page: "/settings/classes", anchor: "cover",
    columns: ["cover_auto_accept_enabled", "cover_escalation_hours"] },
  { id: "availability-confirmations", group: "classes", label: "Availability & confirmations",
    synonyms: ["availability", "due day", "confirm week", "reminders"],
    page: "/settings/classes", anchor: "availability",
    columns: ["availability_due_day", "week_confirm_escalate_days", "week_confirm_enabled",
      "availability_reminders_enabled"] },
  { id: "carry-forward", group: "classes", label: "Carry a silent roster forward",
    synonyms: ["roster", "repeat", "carry over"],
    page: "/settings/classes", anchor: "carry-forward",
    columns: ["carry_forward_enabled", "roster_confirm_days"] },
  { id: "booking-alerts", group: "classes", label: "Booking alerts to instructors",
    synonyms: ["notify", "booking email", "alert"],
    page: "/settings/classes", anchor: "booking-alerts", columns: ["instructor_booking_alerts"] },
  { id: "assignment-confirmations", group: "classes", label: "Confirm assigned classes",
    synonyms: ["confirm", "agree", "accept"],
    page: "/settings/classes", anchor: "assignment-confirmations", columns: ["assignment_confirmations"] },
  { id: "class-reminders", group: "classes", label: "Class reminders to instructors",
    synonyms: ["reminder", "schedule email", "week ahead"],
    page: "/settings/classes", anchor: "class-reminders", columns: ["instructor_class_reminders"] },

  // ---- Memberships & payments ------------------------------------------------
  { id: "pay-schedule", group: "memberships", label: "Instructor pay schedule",
    synonyms: ["payroll", "pay dates", "when paid"],
    page: "/settings/memberships", anchor: "pay-schedule",
    columns: ["pay_period_mode", "pay_period_second_day", "pay_period_anchor",
      "pay_settle_dow", "pay_settle_offset_days", "pay_period_days"] },
  { id: "conversion-bonus", group: "memberships", label: "Conversion bonus",
    synonyms: ["bonus", "commission", "incentive"],
    page: "/settings/memberships", anchor: "conversion",
    columns: ["conversion_bonus_enabled", "conversion_bonus_cents", "conversion_window_days"] },
  { id: "seat-caps", group: "memberships", label: "Limit places on a plan",
    synonyms: ["capacity", "max members", "full", "seat cap"],
    page: "/settings/memberships", anchor: "seat-caps", columns: ["seat_caps_enabled"] },
  { id: "how-to-buy", group: "memberships", label: "How members buy a plan",
    synonyms: ["buy", "purchase", "at the desk"],
    page: "/settings/memberships", anchor: "how-to-buy", columns: ["how_to_buy"] },
  { id: "free-first-class", group: "memberships", label: "First class free",
    synonyms: ["trial", "intro", "free first"],
    page: "/settings/memberships", anchor: "free-first",
    columns: ["free_first_class_enabled", "free_first_peak_allowed", "free_first_core_only",
      "free_first_seats_per_class", "free_first_confirm_at"] },
  { id: "guest-passes", group: "memberships", label: "Bring a guest",
    synonyms: ["guest", "+1", "bring a friend"],
    page: "/settings/memberships", anchor: "guest-passes", columns: ["guest_passes_enabled"] },
  { id: "challenges", group: "memberships", label: "Run challenges",
    synonyms: ["challenge", "goal", "streak"],
    page: "/settings/memberships", anchor: "challenges", columns: ["challenges_enabled"] },
  { id: "membership-plans", group: "memberships", label: "Membership plans",
    synonyms: ["plan", "pack", "price", "credits"],
    page: "/plans", anchor: "plans", standalone: "/plans",
    columns: ["name", "description", "type", "price_cents", "currency", "billing_interval",
      "billing_interval_count", "credits", "credits_per_period", "validity_days",
      "signup_fee_cents", "commitment_months", "cancellation_notice_days", "freeze_allowed",
      "max_freeze_days", "booking_window_days", "max_bookings_per_day", "restrictions",
      "visibility", "status", "sort_order", "counts_for_conversion", "max_active_members",
      "show_remaining_below", "on_limit_reached", "peak_allowance", "peak_allowance_period"] },

  // ---- Communications (all live on the owner-only /branding page) ------------
  // Decision 70(b): Manager may now edit branding, so these are no longer owner-only.
  { id: "member-app-look", group: "communications", label: "Member app look",
    synonyms: ["branding", "colours", "logo", "appearance"],
    page: "/settings/communications", anchor: "member-app", standalone: "/branding" },
  { id: "instructor-names", group: "communications", label: "Instructor names on the website",
    synonyms: ["first name", "full name", "display name"],
    page: "/settings/communications", anchor: "member-app", standalone: "/branding",
    columns: ["public_instructor_name"] },
  { id: "time-display", group: "communications", label: "Show times as 12- or 24-hour",
    synonyms: ["clock", "am pm", "24-hour", "time format"],
    page: "/settings/communications", anchor: "member-app", standalone: "/branding",
    columns: ["time_format"] },
  { id: "studio-contact", group: "communications", label: "Studio contact (reply-to)",
    synonyms: ["reply-to", "support", "contact email", "phone"],
    page: "/settings/communications", anchor: "member-app", standalone: "/branding" },
  { id: "campaign-domain", group: "communications", label: "Campaign sending domain",
    synonyms: ["email domain", "from address", "sending domain"],
    page: "/settings/communications", anchor: "campaign" },

  // ---- Apps & integrations (standalone, owner-only) --------------------------
  { id: "stripe", group: "integrations", label: "Card payments (Stripe)",
    synonyms: ["stripe", "card", "online payment"],
    page: "/settings/integrations", anchor: "stripe", standalone: "/settings/stripe", ownerOnly: true },
  { id: "xendit", group: "integrations", label: "Online payments — Philippines (Xendit)",
    synonyms: ["xendit", "gcash", "maya", "philippines"],
    page: "/settings/integrations", anchor: "xendit", standalone: "/settings/xendit", ownerOnly: true },
  // Decision 70(b): Manager may now edit store apps; Stripe/Xendit stay owner-only.
  { id: "store-apps", group: "integrations", label: "Android & iPhone app verification",
    synonyms: ["app store", "play store", "store apps", "native app"],
    page: "/settings/integrations", anchor: "store-apps", standalone: "/settings/store-apps" },
];

const GROUP_LABEL = Object.fromEntries(GROUPS.map((g) => [g.id, g.label]));
const words = (s) => s.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);

/**
 * Rank: label prefix (0) > label word prefix (1) > synonym prefix (2) >
 * group-name contains (3). Ties broken alphabetically by label. Max 8.
 * Empty query → [] (nothing to suggest until they type).
 * @param {string} query
 * @returns {import('./settings-registry').SettingEntry[]}
 */
export function searchSettings(query) {
  const q = (query ?? "").trim().toLowerCase();
  if (!q) return [];
  const scored = [];
  for (const s of SETTINGS) {
    const label = s.label.toLowerCase();
    let rank = null;
    if (label.startsWith(q)) rank = 0;
    else if (words(s.label).some((w) => w.startsWith(q))) rank = 1;
    else if ((s.synonyms ?? []).some((sy) => sy.toLowerCase().startsWith(q) || words(sy).some((w) => w.startsWith(q)))) rank = 2;
    else if ((GROUP_LABEL[s.group] ?? "").toLowerCase().includes(q)) rank = 3;
    if (rank !== null) scored.push({ rank, s });
  }
  scored.sort((a, b) => a.rank - b.rank || a.s.label.localeCompare(b.s.label));
  return scored.slice(0, 8).map((x) => x.s);
}
