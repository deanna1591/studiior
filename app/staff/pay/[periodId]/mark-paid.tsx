"use client";

import { useFormState, useFormStatus } from "react-dom";
import { markPaid, type PayState } from "../actions";

function Btn() {
  const { pending } = useFormStatus();
  return <button className="rounded bg-ink px-3 py-1.5 text-[12px] font-semibold text-surface disabled:opacity-50" disabled={pending}>{pending ? "Saving…" : "Mark paid"}</button>;
}
const field = "rounded border border-line-2 bg-surface px-2 py-1 text-[12px] text-ink";

export default function MarkPaid({ periodId, instructorId, paid }: {
  periodId: string; instructorId: string; paid: { paid_on: string; method: string } | null;
}) {
  const [state, action] = useFormState<PayState, FormData>(markPaid, null);
  if (state?.ok) return <p className="mt-1 text-[12px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>;
  return (
    <form action={action} className="mt-2 flex flex-wrap items-center gap-1.5">
      <input type="hidden" name="period_id" value={periodId} />
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="date" name="paid_on" defaultValue={paid?.paid_on} className={field} required />
      <select name="method" defaultValue={paid?.method ?? "bank_transfer"} className={field}>
        <option value="bank_transfer">Bank transfer</option><option value="gcash">GCash</option>
        <option value="cash">Cash</option><option value="card">Card</option><option value="other">Other</option>
      </select>
      <input name="reference" placeholder="Reference" className={`${field} w-28`} />
      <input name="proof" type="file" accept="image/png,image/jpeg,image/webp,application/pdf" className="text-[11px]" />
      <Btn />
      {state && !state.ok && <span className="text-[11px] text-ink-2">{state.message}</span>}
    </form>
  );
}
