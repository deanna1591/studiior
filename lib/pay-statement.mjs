// Decision 75b-2 (i) — pure copy helpers for the pay statement, shared by the
// instructor My Pay page and the staff per-instructor statement. Node-tested.
// pay-copy.mjs stays Decision 35's member payment copy — this is separate.

// A ran class line: "N booked · M checked in · paid on M" once finalised,
// "N booked · awaiting attendance" before. A class that did not run / was
// cancelled carries its own status words instead (handled by the caller).
export function classLineText({ booked = 0, checkedIn = null, finalised = false } = {}) {
  const b = `${booked} booked`;
  if (finalised && checkedIn != null) {
    return `${b} · ${checkedIn} checked in · paid on ${checkedIn}`;
  }
  return `${b} · awaiting attendance`;
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
