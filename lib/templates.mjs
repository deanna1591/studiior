// Decision 78c — which notification templates a studio may edit in the composer,
// grouped for the Templates list. Keys must match notification_templates.key.
// The placeholders shown beside the editor are derived from the default wording,
// so they cannot drift from what render_notification actually substitutes.

export const TEMPLATE_GROUPS = [
  {
    title: "Convert — a new member's first days",
    keys: [
      { key: "convert_before_class", label: "Before their first class" },
      { key: "convert_after_class", label: "After their first class" },
      { key: "convert_day3", label: "Day 3 nudge" },
      { key: "convert_day7", label: "Day 7 nudge" },
      { key: "convert_last_day", label: "Last day of the intro offer" },
      { key: "convert_missed_you", label: "Missed-you note" },
    ],
  },
  {
    title: "Keep — renewals, credits, win-backs",
    keys: [
      { key: "keep_renew_7", label: "Plan ends in a week" },
      { key: "keep_renew_1", label: "Plan ends tomorrow" },
      { key: "keep_renew_0", label: "Plan ends today" },
      { key: "keep_lapsed_3", label: "Lapsed 3 days ago" },
      { key: "keep_credits_7", label: "Credits expire in a week" },
      { key: "keep_credits_2", label: "Credits expire in 2 days" },
      { key: "keep_winback_30", label: "Win-back at 30 days" },
      { key: "keep_winback_60", label: "Win-back at 60 days" },
      { key: "keep_drifting", label: "Drifting — a gentle check-in" },
    ],
  },
  {
    title: "Retention tasks — the message you copy",
    keys: [
      { key: "task_unconverted_message", label: "Not-yet-converted reach-out" },
      { key: "task_at_risk_message", label: "At-risk reach-out" },
    ],
  },
  {
    title: "Retention — the email you send from the board",
    keys: [
      { key: "retention_unconverted", label: "Not yet converted" },
      { key: "retention_at_risk", label: "At risk" },
      { key: "retention_drifting", label: "Drifting" },
      { key: "retention_expiring", label: "Membership expiring" },
      { key: "retention_lapsed", label: "Lapsed — win-back" },
    ],
  },
  {
    title: "Closures",
    keys: [{ key: "studio_closure_notice", label: "Studio closure notice" }],
  },
  {
    title: "Instructors",
    keys: [
      { key: "instructor_class_ended_unmarked", label: "Class ended — bookings still unmarked" },
    ],
  },
];

const EDITABLE = new Set(TEMPLATE_GROUPS.flatMap((g) => g.keys.map((k) => k.key)));

/** True when a key is one of the composer-editable templates. */
export function isEditableTemplate(key) {
  return EDITABLE.has(key);
}

/** Label for a key, or the key itself if unknown. */
export function templateLabel(key) {
  for (const g of TEMPLATE_GROUPS) for (const k of g.keys) if (k.key === key) return k.label;
  return key;
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
