"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { setSeatFeeChoice, recordPaidAtStudio, type FeeActionState } from "@/app/staff/roster/fee-actions";

function Btn({ children, tone = "plain" }: { children: React.ReactNode; tone?: "plain" | "solid" }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending}
            className="whitespace-nowrap rounded-full px-3 py-1 text-[12px] font-semibold disabled:opacity-50"
            style={tone === "solid"
              ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
              : { background: "var(--surface)", color: "var(--ink)", boxShadow: "inset 0 0 0 1px var(--line-2)" }}>
      {pending ? "Saving…" : children}
    </button>
  );
}

function Line({ s }: { s: FeeActionState }) {
  if (!s) return null;
  return "error" in s
    ? <span className="text-[12px] text-ink-2" role="alert">{s.error}</span>
    : <span className="text-[12px] text-lime-text">{s.ok}</span>;
}

/** Decision 103 (n): beside the reservation chip on the staff and coach rosters.
 *  A due seat (staff only): Pays at the studio / Waive. A pays-at-the-studio
 *  seat (staff or the coach): Paid at studio, amount fixed to the fee. */
export default function SeatFeeActions({ bookingId, occurrenceId, state, feeText, canChoose }: {
  bookingId: string; occurrenceId: string; state: string | null | undefined; feeText: string; canChoose: boolean;
}) {
  const [choiceState, choose] = useFormState(setSeatFeeChoice, null);
  const [paidState, pay] = useFormState(recordPaidAtStudio, null);
  const [open, setOpen] = useState(false);

  if ((state === "due" || state === "not_asked") && canChoose) {
    return (
      <span className="flex flex-wrap items-center gap-1.5" data-testid="seat-fee-choice">
        {(["studio", "waive"] as const).map((c) => (
          <form key={c} action={choose}>
            <input type="hidden" name="booking_id" value={bookingId} />
            <input type="hidden" name="occurrence_id" value={occurrenceId} />
            <input type="hidden" name="choice" value={c} />
            <Btn>{c === "studio" ? "Pays at the studio" : "Waive"}</Btn>
          </form>
        ))}
        <Line s={choiceState} />
      </span>
    );
  }
  if (state === "at_studio") {
    if (!open) {
      return (
        <span className="flex items-center gap-1.5">
          <button type="button" onClick={() => setOpen(true)} data-testid="paid-at-studio"
                  className="whitespace-nowrap rounded-full px-3 py-1 text-[12px] font-semibold"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
            Paid at studio
          </button>
          <Line s={paidState} />
        </span>
      );
    }
    return (
      <form action={pay} className="flex w-full flex-wrap items-center gap-2 rounded-lg bg-paper px-3 py-2"
            data-testid="paid-at-studio-form">
        <input type="hidden" name="booking_id" value={bookingId} />
        <input type="hidden" name="occurrence_id" value={occurrenceId} />
        <span className="text-[13px] text-ink">Amount <span className="num font-semibold">{feeText}</span></span>
        <select name="method" defaultValue="cash"
                className="rounded-lg border border-line-2 bg-surface px-2 py-1 text-[13px] text-ink">
          <option value="cash">Cash</option>
          <option value="gcash">GCash</option>
          <option value="card_terminal">Card terminal</option>
          <option value="bank_transfer">Bank transfer</option>
          <option value="other">Other</option>
        </select>
        <input name="reference" placeholder="Reference (optional)"
               className="min-w-[9rem] flex-1 rounded-lg border border-line-2 bg-surface px-2 py-1 text-[13px] text-ink" />
        <Btn tone="solid">Record</Btn>
        <button type="button" onClick={() => setOpen(false)} className="text-[12px] text-ink-2 underline">Cancel</button>
        <Line s={paidState} />
      </form>
    );
  }
  return null;
}
