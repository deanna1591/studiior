// Decision 106 — the score a growth slot is ranked by, and the rules around it.
//
// This is the authoritative spec; the SQL in growth_insights() mirrors it
// line for line (each piece is labelled there with the name it carries here).
// A boutique studio's weekly "which classes earn core, which stay flex" is a
// judgement about demand, so the inputs are only what already happened in the
// room: how full it got, whether the booked members turned up, who joined the
// waitlist, and the two things that waste a slot — no-shows and late cancels.

export const RECENT_WEEKS = 4; // the window the qualifying rule and raise signal key on
export const HISTORY_WEEKS = 8; // how far back the score looks

// Booked of capacity, clamped at 1.0 — comps, guests and walk-ins can push a
// room past its capacity, and a slot is not "160% in demand", it is full.
export function clampFrac(booked, capacity) {
  if (!capacity || capacity <= 0) return 0;
  return Math.min(Math.max(booked, 0) / capacity, 1);
}

// One past class's score. Fullness carries it (0.6); attendance among those who
// held a seat tempers it (0.25); a waitlist is a small positive demand signal
// (0.15, capped so a long waitlist does not dominate); no-shows and late
// cancels are the waste that pulls it down (0.2).
export function occScore(w) {
  const bookedFrac = clampFrac(w.booked, w.capacity);
  const booked = Math.max(w.booked ?? 0, 0);
  const attendedFrac = booked > 0 ? Math.min(Math.max(w.attended ?? 0, 0) / booked, 1) : 0;
  const cap = Math.max(w.capacity ?? 0, 1);
  const waitSignal = Math.min(Math.max(w.waitlist ?? 0, 0) / cap, 0.5);
  const penalty = (Math.max(w.noShow ?? 0, 0) + Math.max(w.lateCancel ?? 0, 0)) / cap;
  return 0.6 * bookedFrac + 0.25 * attendedFrac + 0.15 * waitSignal - 0.2 * penalty;
}

// weeks are newest first. The last RECENT_WEEKS count double, so a slot that has
// turned a corner recently is read for what it is doing now.
export function weightFor(idx) {
  return idx < RECENT_WEEKS ? 2 : 1;
}

export function slotScore(weeks) {
  if (!weeks || weeks.length === 0) return 0;
  let num = 0;
  let den = 0;
  weeks.forEach((w, i) => {
    const wt = weightFor(i);
    num += wt * occScore(w);
    den += wt;
  });
  return den ? num / den : 0;
}

// Four weeks of its own history, or no proposal.
export function hasEnoughHistory(n) {
  return (n ?? 0) >= RECENT_WEEKS;
}

export function collectingLabel(n) {
  return `Collecting data, ${n} of ${RECENT_WEEKS} weeks`;
}

// A slot qualifies as core only if it reached the studio's flex minimum in three
// of the last four weeks (weeks newest first). Only meaningful once there are
// four weeks; before that there is no proposal at all.
export function qualifies(weeks, flexMin) {
  if (!hasEnoughHistory(weeks?.length ?? 0)) return false;
  const last4 = weeks.slice(0, RECENT_WEEKS);
  const met = last4.filter((w) => (w.booked ?? 0) >= flexMin).length;
  return met >= 3;
}
