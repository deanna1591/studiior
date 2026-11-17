/**
 * Decision 112 weekly campaigns — pure display helpers shared by the Campaigns
 * page. The matcher, the sweep and the exclusions live in SQL (campaign_member_matches,
 * campaign_audience_for, sweep_weekly_campaigns); nothing here decides who gets an
 * email. These only turn an audience's stored shape into words, and give the
 * quiet-rule a testable mirror for the preview copy.
 */

// The conditions jsonb, in plain words. One clause per key, in a stable order.
export function conditionLabels(conditions) {
  const c = conditions || {};
  const out = [];
  if (c.status) out.push(`status is ${c.status}`);
  if (c.has_plan === true) out.push("has a plan");
  if (c.has_plan === false) out.push("has no plan");
  if (c.free_done === true) out.push("took a free class");
  if (c.free_done === false) out.push("no free class");
  if (c.never_booked === true) out.push("never booked");
  if (typeof c.class_types_min === "number") out.push(`tried at least ${c.class_types_min}`);
  if (typeof c.class_types_max === "number") out.push(`tried at most ${c.class_types_max}`);
  if (typeof c.joined_min_days === "number") out.push(`signed up over ${c.joined_min_days} days ago`);
  if (typeof c.last_visit_min_days === "number") out.push(`${c.last_visit_min_days} days since their last visit`);
  if (typeof c.credits_left_max === "number") out.push(`${c.credits_left_max} credits or fewer left`);
  return out;
}

// A one-line cadence summary, e.g. "Every 1 week, up to 5, then monthly".
export function cadenceLine(a) {
  const weeks = Number(a?.cadence_weeks || 1);
  const every = weeks === 1 ? "Every week" : `Every ${weeks} weeks`;
  const cap = a?.max_weekly ? `, up to ${a.max_weekly}` : "";
  const monthly = a?.monthly_mode === "monthly" ? ", then monthly" : ", then stop";
  return `${every}${cap}${monthly}`;
}

// The 3-day quiet rule, as a testable predicate: a member who got any studio
// email within `days` days is held back. nowMs/lastMs are epoch millis; lastMs
// null means never emailed (not blocked).
export function quietBlocked(lastMs, nowMs, days = 3) {
  if (lastMs == null) return false;
  return lastMs > nowMs - days * 24 * 60 * 60 * 1000;
}
