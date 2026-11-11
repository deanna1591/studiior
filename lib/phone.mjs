// Decision 94 — the one place a member's phone number is normalised and shown.
//
// normalisePhone(country, input) returns the canonical E.164 value to store, or
// null when the input is not a usable mobile number. When the studio's country
// is PH the number must be a Philippine mobile (09XXXXXXXXX or +639XXXXXXXXX);
// otherwise any 7 to 15 digit number is accepted. The stored value is E.164
// (+639171234567); formatPhone() renders it for display (+63 9XX XXX XXXX).

/** Canonical E.164 for storage, or null when it is not a usable number. */
export function normalisePhone(country, input) {
  if (input == null) return null;
  const raw = String(input).trim();
  if (raw === "") return null;
  const hasPlus = raw.startsWith("+");
  const digits = raw.replace(/\D/g, "");

  if (String(country ?? "").toUpperCase() === "PH") {
    // 09XXXXXXXXX (local) -> drop the leading 0, prefix +63.
    if (/^09\d{9}$/.test(digits)) return "+63" + digits.slice(1);
    // 639XXXXXXXXX (international), with or without the +.
    if (/^639\d{9}$/.test(digits)) return "+" + digits;
    return null;
  }

  // Any other country: 7 to 15 digits, kept as entered (E.164 when a + was given).
  if (digits.length < 7 || digits.length > 15) return null;
  return (hasPlus ? "+" : "") + digits;
}

/** A stored number for display. PH numbers read +63 9XX XXX XXXX. */
export function formatPhone(stored) {
  if (!stored) return "";
  const s = String(stored).trim();
  // +639171234567 -> +63 917 123 4567
  const m = /^\+63(9\d{9})$/.exec(s);
  if (m) {
    const d = m[1];
    return `+63 ${d.slice(0, 3)} ${d.slice(3, 6)} ${d.slice(6)}`;
  }
  return s;
}

/** The one copy for a number that does not pass validation. */
export const PHONE_INVALID = "That doesn't look like a mobile number.";
