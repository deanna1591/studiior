"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { addException, removeException, type AvailState } from "./actions";

export type Exception = {
  date: string;
  available: boolean;
  ranges: { from: string; to: string }[];
  note: string | null;
  /** Formatted on the SERVER. A function cannot cross the client boundary —
      Next refuses it at runtime, and TypeScript is happy either way, so this
      only shows up when the page is actually opened. */
  label: string;
};

/**
 * Dated exceptions, listed apart from the week.
 *
 * A separate act from editing the pattern, and separate on the screen for the
 * same reason: the pattern is the three-month commitment, an exception is a
 * Tuesday in September. Re-entering the week must not silently forget one, and
 * the reference lays them out beside the week rather than inside it.
 */
export default function Exceptions({
  instructorId, exceptions, canEdit,
}: {
  instructorId: string;
  exceptions: Exception[];
  canEdit: boolean;
}) {
  const [addState, add] = useFormState<AvailState, FormData>(addException, null);
  const [rmState, rm] = useFormState<AvailState, FormData>(removeException, null);
  const state = addState ?? rmState;

  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {exceptions.length === 0 ? (
        <p className="text-[13px] leading-[20px] text-ink-3">
          Nothing yet. Planned absences go here so the pattern above stays the
          agreement rather than being edited around every holiday.
        </p>
      ) : (
        <ul className="space-y-1">
          {exceptions.map((e) => (
            <li key={e.date} className="flex items-center gap-3 rounded-xl bg-paper px-3.5 py-2.5">
              <span className="num min-w-0 flex-1 text-[13px] leading-[20px] text-ink">
                {e.label}
              </span>
              <span className="shrink-0 text-[13px] leading-[20px] text-ink-2">
                {e.available && e.ranges.length > 0
                  ? e.ranges.map((r) => `${r.from} – ${r.to}`).join(", ")
                  : "Unavailable"}
              </span>
              {canEdit && (
                <form action={rm} className="shrink-0">
                  <input type="hidden" name="instructor_id" value={instructorId} />
                  <input type="hidden" name="date" value={e.date} />
                  <RemoveBtn label={`Remove the exception on ${e.label}`} />
                </form>
              )}
            </li>
          ))}
        </ul>
      )}

      {canEdit && (
        <form action={add} className="mt-4 flex flex-wrap items-end gap-3 border-t border-line pt-4">
          <input type="hidden" name="instructor_id" value={instructorId} />
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">Date</span>
            <input type="date" name="date" required className={inputClass} />
          </label>
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">From</span>
            <input type="time" name="from" className={inputClass} />
          </label>
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">To</span>
            <input type="time" name="to" className={inputClass} />
          </label>
          <AddBtn />
          {/* The common case is the empty one, so it is what the hint
              describes rather than an edge case mentioned at the end. */}
          <p className="w-full text-[12px] leading-[18px] text-ink-3">
            Leave the times blank for a whole day off — that is what a planned
            absence usually is. Fill them in for a day they can only do part of.
          </p>
        </form>
      )}
    </div>
  );
}

function AddBtn() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-lg border border-line-2 bg-surface px-3.5 py-2 text-[13px] font-medium text-ink disabled:opacity-60">
      {pending ? "…" : "Add"}
    </button>
  );
}

function RemoveBtn({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending} aria-label={label}
            className="rounded-md px-1.5 py-1 text-[15px] leading-none text-ink-3 disabled:opacity-60">
      ×
    </button>
  );
}
