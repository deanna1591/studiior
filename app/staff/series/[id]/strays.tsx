"use client";

import { useFormState, useFormStatus } from "react-dom";
import { moveStrayToTemplate, type MoveBackState } from "../actions";

export type Stray = {
  id: string;
  whenLabel: string;      // "Wed 11 Nov 18:00"
  occTime: string;        // "18:00"
  seriesTime: string;     // "07:00"
  kind: "time" | "weekday";
  booked: number;
};

function MoveBack({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<MoveBackState, FormData>(moveStrayToTemplate, null);
  return (
    <form action={action} className="shrink-0">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <MoveButton />
      {state && !state.ok && (
        <span className="ml-2 text-[12px] text-coral-deep">{state.message}</span>
      )}
      {state && state.ok && (
        <span className="ml-2 text-[12px] text-ink-2">{state.message}</span>
      )}
    </form>
  );
}
function MoveButton() {
  const { pending } = useFormStatus();
  return (
    <button className="rounded-lg border border-line-2 bg-surface px-2.5 py-1 text-[12px] text-ink-2 disabled:opacity-60"
            disabled={pending}>
      {pending ? "Moving…" : "Move back"}
    </button>
  );
}

/**
 * Decision 42a amendment (c) — "Classes not at the usual time". The series'
 * future occurrences whose studio-local time or weekday differs from the
 * template, each fixable to the template time in one click. No automatic
 * correction: a stray may be deliberate, and moving a booked class emails its
 * members.
 */
export default function StrayClasses({ strays }: { strays: Stray[] }) {
  if (strays.length === 0) return null;
  return (
    <div className="mb-6 max-w-xl rounded border-l-[3px] px-3.5 py-3"
         style={{ borderLeftColor: "var(--amber-deep)", background: "var(--amber-tint)" }}>
      <p className="text-[12px] font-semibold uppercase tracking-[0.04em] text-ink-2">
        Classes not at the usual time
      </p>
      <p className="mt-1 text-[13px] leading-[19px] text-ink-2">
        These sit at a different time or on a different day from the recurring
        class. Move one back to {strays[0].seriesTime} — or leave it, if it is
        meant to be where it is.
      </p>
      <ul className="mt-2.5 flex flex-col gap-2">
        {strays.map((s) => (
          <li key={s.id} className="flex items-center justify-between gap-3">
            <span className="min-w-0 text-[13px] leading-[18px] text-ink">
              <span className="num">{s.whenLabel}</span>
              <span className="text-ink-2">
                {" "}· {s.kind === "weekday" ? "different day" : `usual time ${s.seriesTime}`}
                {s.booked > 0 && <> · <span className="num">{s.booked}</span> booked</>}
              </span>
            </span>
            <MoveBack occurrenceId={s.id} />
          </li>
        ))}
      </ul>
    </div>
  );
}
