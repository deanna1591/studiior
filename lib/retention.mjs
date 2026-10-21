// Decision 79a — the retention page's plain words. State line, outcome line,
// and the snooze offsets, as pure functions so the panel and a node test agree.

/** The free cohort's stage as a verb. */
export function freeStageWord(stage) {
  return stage === "taken" ? "taken" : stage === "missed" ? "missed" : "booked";
}

/** How a contact's method reads as a past-tense verb. */
export function methodWord(method) {
  return method === "email" ? "Emailed"
    : method === "viber" ? "Messaged on Viber"
    : method === "call" ? "Called"
    : method === "in_person" ? "Spoke in person"
    : "Contacted";
}

/** The outcome as a short clause: what they did and how long after. */
export function outcomeClause(outcome, outcomeDays) {
  if (!outcome) return null;
  if (outcome === "none") return "No change after 14 days";
  const verb = outcome === "booked" ? "Booked"
    : outcome === "visited" ? "Came back"
    : outcome === "bought" ? "Bought a plan"
    : outcome === "renewed" ? "Renewed" : "Responded";
  const n = outcomeDays ?? 0;
  return `${verb} ${n} day${n === 1 ? "" : "s"} later`;
}

/** The full line under a row: "Emailed 3 days ago · Booked 2 days later". */
export function outcomeLine({ method, contactedAt, outcome, outcomeDays, now = Date.now() }) {
  if (!contactedAt) return null;
  const days = Math.max(0, Math.floor((now - new Date(contactedAt).getTime()) / 86400000));
  const head = `${methodWord(method)} ${days === 0 ? "today" : `${days} day${days === 1 ? "" : "s"} ago`}`;
  const tail = outcomeClause(outcome, outcomeDays);
  return tail ? `${head} · ${tail}` : head;
}

/**
 * The member's situation in plain words, from the snapshot. Health bands already
 * carry a written reason ("Was coming about every 4 days, last visit 13 days
 * ago"), so an at-risk/drifting member reads that; a free-only member reads their
 * stage; an expiring/active member reads their plan and date.
 */
export function stateLine(s, { daysAgo } = {}) {
  if (!s) return "";
  const days = s.last_contact_at ? null : (s.days_since ?? daysAgo);
  if (s.plan_state === "free_only") {
    const when = s.free_stage && days != null
      ? ` ${days} day${days === 1 ? "" : "s"} ago` : "";
    return `Free class ${freeStageWord(s.free_stage)}${when} · no plan yet`;
  }
  if ((s.health_band === "at_risk" || s.health_band === "drifting") && s.health_reason) {
    return s.health_reason;
  }
  if (s.plan_state === "expiring" && s.current_plan_name && s.expires_on) {
    return `${s.current_plan_name} ends ${s.expires_on}`;
  }
  if (s.plan_state === "expired") return `${s.current_plan_name ?? "Their plan"} has ended`;
  if (s.plan_state === "none") return "Signed up, nothing booked";
  if (s.current_plan_name) return `On ${s.current_plan_name}`;
  return "On a plan";
}

/** The snooze choices the panel offers. */
export const SNOOZE_DAYS = [3, 7, 14];
export function snoozeLabel(days) {
  return `Remind me in ${days} day${days === 1 ? "" : "s"}`;
}
