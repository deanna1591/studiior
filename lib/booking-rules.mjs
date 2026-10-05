// Pure helpers for the booking-rule settings (the cancellation cut-off is
// entered as hours + minutes and stored as total minutes in
// cancellation_cutoff_minutes). Plain ESM so a server action, a client panel
// and `node --test` can all import it — the repo has no JS runner for .ts.

/** A non-negative whole number, or the fallback. The /welcome validation,
 *  extracted so the wizard and the settings page clamp identically. */
export function clampInt(raw, fallback) {
  const n = Number(String(raw ?? "").trim());
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : fallback;
}

/** Compose hours + minutes into total minutes (what the column stores). */
export function cutoffMinutes(hoursRaw, minutesRaw) {
  return clampInt(hoursRaw, 0) * 60 + clampInt(minutesRaw, 0);
}

/** Split a stored total back into whole hours and the remaining minutes. */
export function cutoffParts(total) {
  const t = clampInt(total, 0);
  return { hours: Math.floor(t / 60), minutes: t % 60 };
}

/** Human form of a stored total: 720 → "12 h", 750 → "12 h 30 m", 45 → "45 m",
 *  0 → "no cut-off" (a member can cancel right up to the start). */
export function cutoffLabel(total) {
  const t = clampInt(total, 0);
  if (t <= 0) return "no cut-off";
  const h = Math.floor(t / 60), m = t % 60;
  if (h === 0) return `${m} m`;
  if (m === 0) return `${h} h`;
  return `${h} h ${m} m`;
}
