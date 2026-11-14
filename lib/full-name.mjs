// Decision 102 — one name stays one name. A member's full name is the first
// name alone when the last name is empty; nothing shows "First " with a
// trailing space, and nothing copies the first name into the last name.
// The one place a first/last pair becomes a displayed full name.

/** First and last joined, or the first alone when the last is empty. */
export function fullName(first, last) {
  const f = String(first ?? "").trim();
  const l = String(last ?? "").trim();
  return l ? `${f} ${l}` : f;
}
