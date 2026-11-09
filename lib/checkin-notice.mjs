// Decision 35 amendment (10 Nov 2026) — the QR / class-page check-in notice.
//
// Pure: picks ONE member-facing sentence from the member's most-relevant
// booking and the window. The page decides WHICH booking (the one in its
// window, else the next today, else the last closed today) and does the
// studio-clock formatting via `fmt`; this decides the words. Kept out of the
// page so the states are node-tested without a browser. No em dashes.
//
// kind:
//   'open'     — window open and the waiver is fine (the button shows; no notice)
//   'waiver'   — in the window but the studio waiver is unsigned
//   'not_open' — booked today, the window has not opened yet
//   'closed'   — booked today, the window has passed
//   'none'     — no booking to check in to right now

const MIN = 60_000;

export function checkinNotice({ booking, now, opensBefore, closesAfter, waiverOk, fmt } = {}) {
  if (!booking) {
    return { kind: "none", text: "No class to check in to right now." };
  }
  const f = typeof fmt === "function" ? fmt : (ms) => String(ms);
  const opensAt = booking.startsAt - opensBefore * MIN;
  const closesAt = (booking.endsAt ?? booking.startsAt) + closesAfter * MIN;

  if (now < opensAt) {
    return {
      kind: "not_open",
      text: `You're booked for ${booking.name} at ${f(booking.startsAt)}. You can check in ${opensBefore} minutes before class.`,
    };
  }
  if (now > closesAt) {
    return {
      kind: "closed",
      text: `Check-in for ${booking.name} closed at ${f(closesAt)}. Check in with your instructor.`,
    };
  }
  // In the window.
  if (!waiverOk) {
    return { kind: "waiver", text: "Please sign the waiver first before checking in." };
  }
  return { kind: "open", text: null };
}
