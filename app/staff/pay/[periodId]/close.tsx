"use client";

import { useFormState, useFormStatus } from "react-dom";
import { closePeriod, type CloseState } from "../actions";

function Btn() {
  const { pending } = useFormStatus();
  return (
    <button className="rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-paper disabled:opacity-60" disabled={pending}>
      {pending ? "Closing…" : "Close period"}
    </button>
  );
}

/**
 * Decision 75b-2 (h): closing a period is a manager's deliberate act. When
 * class records are still held (an instructor has not checked in, or a manager
 * has not released them) the period cannot close — we show WHICH classes, as a
 * reason, not an error toast.
 */
export default function ClosePeriod({ periodId }: { periodId: string }) {
  const [state, action] = useFormState<CloseState, FormData>(closePeriod, null);
  return (
    <div className="max-w-2xl">
      <form action={action}>
        <input type="hidden" name="period_id" value={periodId} />
        <Btn />
      </form>
      {state && !state.ok && (
        <div className="mt-2 rounded border-l-[3px] bg-surface px-3 py-2.5" style={{ borderLeftColor: "var(--coral)" }}>
          <p className="text-[13px] text-ink">{state.message}</p>
          {state.held && state.held.length > 0 && (
            <ul className="mt-1.5 space-y-1">
              {state.held.map((h, i) => (
                <li key={i} className="text-[12px] text-ink-2">
                  {h.name} · {h.when} · {h.instructor}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
      {state?.ok && <p className="mt-2 text-[13px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>}
    </div>
  );
}
