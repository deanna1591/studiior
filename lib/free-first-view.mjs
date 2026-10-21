// Decision 55 follow-up — pure helpers for the free-class view on the Book tab.
// The button and the rule must never contradict each other: "Book free" shows
// only where a free booking actually works. Node-tested, no RPC.

// The occurrence ids where a free booking actually succeeds (present in
// free_first_class_list AND still free-bookable — a full-for-free class is in
// the list but pays, so it is NOT here). This drives "Book free" on the
// timetable; every other row gets the paid Book button + the muted note.
export function freeEligibleSet(freeList = []) {
  return new Set((freeList || []).filter((c) => c && c.free_bookable).map((c) => c.occurrence_id));
}

// Which view the Book tab opens with: the picker (primary) when the member is
// eligible, has at least one eligible class, and has not asked for the full
// timetable (?all=1); otherwise the regular timetable.
export function whichView({ freeFirstEligible = false, eligibleCount = 0, showAll = false } = {}) {
  return freeFirstEligible && eligibleCount > 0 && !showAll ? "picker" : "timetable";
}

// Decision 30 amendment (b) follow-up — the calendar block's trials marker shows
// EXCEPTIONS in both directions, and ONLY exceptions:
//   "trials"    — an override OPENS a class the studio rules would CLOSE;
//   "no_trials" — an override CLOSES a class the studio rules would OPEN;
//   null        — the override merely repeats the rules, or there is none. A pill
//                 on every rules-open core class would say nothing.
// effective_free_first returns rules_open (the rules, ignoring the override), which
// is exactly what tells an exception from a repeat.
export function trialsMarker(freeFirst) {
  if (!freeFirst) return null;
  if (freeFirst.override === "open" && freeFirst.rulesOpen === false) return "trials";
  if (freeFirst.override === "closed" && freeFirst.rulesOpen === true) return "no_trials";
  return null;
}

// The studio-local day key the picker opens on for a ?d= deep link: that day if
// it has an eligible class, else the nearest day that does (tie → the earlier).
// dayKeys are the eligible classes' studio-local YYYY-MM-DD keys.
export function nearestEligibleDay(dayKeys = [], wanted = null) {
  const keys = [...new Set((dayKeys || []).filter(Boolean))].sort();
  if (keys.length === 0) return null;
  if (!wanted || !/^\d{4}-\d{2}-\d{2}$/.test(wanted)) return keys[0];
  if (keys.includes(wanted)) return wanted;
  const wd = Date.parse(`${wanted}T00:00:00Z`);
  let best = keys[0], bestDist = Infinity;
  for (const k of keys) {
    const dist = Math.abs(Date.parse(`${k}T00:00:00Z`) - wd);
    if (dist < bestDist) { bestDist = dist; best = k; }
  }
  return best;
}
