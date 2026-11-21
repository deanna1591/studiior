// Decision 103 (i): the one reservation-state chip for a free first class seat.
// The database decides the state (free_seat_reservation_state_run); this only
// words it, so the staff roster, the coach's roster and the profile card agree.

/** @param {{state: string|null, feeCents?: number, currency?: string, deadlineLabel?: string}} s
 *  @param {(cents: number, currency: string) => string} fmtMoney */
export function reservationChip(s, fmtMoney) {
  if (!s || !s.state) return null;
  switch (s.state) {
    case "paid":
      return { text: `Paid ${fmtMoney(s.feeCents ?? 0, s.currency ?? "")}`, tone: "ok" };
    case "covered":
      return { text: "Credit covers", tone: "ok" };
    case "waived":
      return { text: "Fee waived", tone: "muted" };
    case "due":
      return { text: s.deadlineLabel ? `Due by ${s.deadlineLabel}` : "Due", tone: "warn" };
    case "not_asked":
      return { text: "Not asked", tone: "warn" };
    default:
      return null;
  }
}

/** Flex pending: one line per class, not per seat. */
export function freeSeatsLine({ n, paid, due, waived }) {
  if (!n) return null;
  return `${n} free seat${n === 1 ? "" : "s"}: ${paid} paid, ${due} due, ${waived} waived`;
}
