// Decision 75b-2 (i) — pure copy helpers for the pay statement, shared by the
// instructor My Pay page and the staff per-instructor statement. Node-tested.
// pay-copy.mjs stays Decision 35's member payment copy — this is separate.

// A ran class line: "N booked · M checked in · paid on H" once finalised,
// "N booked · awaiting attendance" before. H is the heads paid (Decision 75(j):
// the greater of the cut-off count and the seats consumed); a line finalised
// before 75(j) carries no headsPaid and was paid on M. A class that did not run
// or was cancelled carries its own status words instead (handled by the caller).
export function classLineText({ booked = 0, checkedIn = null, headsPaid = null, finalised = false, fullHouse = false, holdingFee = false } = {}) {
  const b = `${booked} booked`;
  // Decision 75 (l): an always-runs class that ran with nobody pays the holding
  // fee; a class whose heads reached capacity pays the full-house total.
  const tail = holdingFee ? " · nobody came, holding fee" : fullHouse ? " · full house" : "";
  if (finalised && checkedIn != null) {
    return `${b} · ${checkedIn} checked in · paid on ${headsPaid ?? checkedIn}${tail}`;
  }
  return `${b} · awaiting attendance${tail}`;
}

// The status words on a class that did not run or was cancelled. pay_statement
// sends "did not run" or "cancelled — {cause}"; a member-facing word for each
// cause, never the raw enum.
export function lineStatusWords(status) {
  if (!status) return "";
  if (status === "did not run") return "Did not run";
  const cause = String(status).replace(/^cancelled\s*\W*\s*/, "");
  switch (cause) {
    case "studio_fault":        return "Cancelled by the studio";
    case "force_majeure":       return "Cancelled for a typhoon or suspension";
    case "closure":             return "Studio closed";
    case "no_instructor":       return "Cancelled, no instructor";
    case "replaced_by_private": return "Replaced by a private session";
    case "unmet_minimum":       return "Did not run";
    default:                    return "Cancelled";
  }
}

// Open / Closed / Paid chip. Paid wins (a settlement row exists).
export function statusChip(status) {
  switch (status) {
    case "paid":   return { label: "Paid", tone: "paid" };
    case "closed": return { label: "Closed", tone: "closed" };
    default:       return { label: "Open", tone: "open" };
  }
}

// Header money/date line. settleOn / paidOn are already-formatted date strings.
export function settleWording({ status, settleOn = null, paidOn = null, method = null } = {}) {
  if (status === "paid" && paidOn) {
    const m = method ? ` · ${String(method).replace(/_/g, " ")}` : "";
    return `Paid ${paidOn}${m}`;
  }
  if (settleOn) return `Payment expected ${settleOn}`;
  return "";
}

// "Something looks wrong?" — a mailto to the studio, the line prefilled. No new
// table; the studio's own contact email is the channel.
export function disputeMailto({ email, periodLabel = "", lineName = "", lineWhen = "", amount = "" } = {}) {
  if (!email) return null;
  const subject = `Pay statement ${periodLabel}`.trim();
  const body = [
    "Hi,",
    "",
    "Something looks wrong on my pay statement:",
    `  ${[lineName, lineWhen, amount].filter(Boolean).join(" · ")}`,
    "",
    "Could you take a look? Thanks.",
  ].join("\n");
  return `mailto:${email}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}
