import { reservationChip } from "@/lib/reservation-chip";
import { formatMoney } from "@/lib/format-money";

export type SeatState = {
  booking_id: string; state: string | null; fee_cents: number | null;
  currency: string | null; deadline_label: string | null;
};

const TONE: Record<string, { background: string; color: string }> = {
  ok:    { background: "var(--lime-tint)", color: "var(--ink)" },
  muted: { background: "var(--paper)", color: "var(--ink-2)" },
  warn:  { background: "var(--amber-tint)", color: "var(--ink)" },
};

/** Decision 103 (i): one chip per free first class seat. */
export default function ReservationChip({ s }: { s: SeatState | undefined }) {
  if (!s) return null;
  const c = reservationChip({ state: s.state, feeCents: s.fee_cents ?? 0,
    currency: s.currency ?? "", deadlineLabel: s.deadline_label ?? undefined }, formatMoney);
  if (!c) return null;
  return (
    <span className="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold"
          style={TONE[c.tone]} data-testid="reservation-chip">
      {c.text}
    </span>
  );
}
