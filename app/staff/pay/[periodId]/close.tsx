"use client";

import { useState, useTransition } from "react";
import { useFormState, useFormStatus } from "react-dom";
import Link from "next/link";
import { closePeriod, resolveClass, resolveAllRan, type CloseState, type HeldClass } from "../actions";

function Btn() {
  const { pending } = useFormStatus();
  return (
    <button className="rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-paper disabled:opacity-60" disabled={pending}>
      {pending ? "Closing…" : "Close period"}
    </button>
  );
}

/**
 * Decision 115: a class with no check-in recorded blocks the close. The manager
 * resolves each listed class — "Ran as scheduled, pay the coach" always, and
 * "Did not run" only when it is empty; a class with members booked offers a link
 * to the normal Cancel class (which refunds and notifies). "Resolve all as ran"
 * settles every listed class at once.
 */
function HeldRow({ h, periodId, onDone }: { h: HeldClass; periodId: string; onDone: () => void }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const booked = Number(h.booked) > 0;
  const act = (choice: "ran" | "did_not_run") =>
    start(async () => {
      setErr(null);
      const r = await resolveClass(h.occurrence_id, choice, periodId);
      if (!r.ok) { setErr(r.error ?? "Could not resolve."); return; }
      onDone();
    });
  return (
    <li className="border-b border-line py-2 last:border-0">
      <div className="text-[12.5px] text-ink">{h.name} · {h.when} · {h.instructor}
        {booked && <span className="text-ink-3"> · {h.booked} booked</span>}</div>
      <div className="mt-1 flex flex-wrap items-center gap-2">
        <button disabled={pending} onClick={() => act("ran")}
          className="rounded-full border border-line-2 bg-surface px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-60">
          Ran as scheduled
        </button>
        {booked ? (
          <Link href={`/roster/${h.occurrence_id}`} className="text-[12px] text-ink-2 underline underline-offset-2">
            Members booked — cancel the class
          </Link>
        ) : (
          <button disabled={pending} onClick={() => act("did_not_run")}
            className="rounded-full border border-line-2 bg-surface px-3 py-1 text-[12px] text-ink-2 disabled:opacity-60">
            Did not run
          </button>
        )}
        {err && <span className="text-[11px] text-ink-2">{err}</span>}
      </div>
    </li>
  );
}

export default function ClosePeriod({ periodId }: { periodId: string }) {
  const [state, action] = useFormState<CloseState, FormData>(closePeriod, null);
  const [allPending, startAll] = useTransition();
  const [note, setNote] = useState<string | null>(null);
  const bump = () => { setNote(null); };  // the action revalidates; re-press Close

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
            <>
              <div className="mt-2 flex items-center justify-between">
                <span className="text-[12px] text-ink-3">{state.held.length} class{state.held.length === 1 ? "" : "es"} to resolve</span>
                <button disabled={allPending}
                  onClick={() => startAll(async () => {
                    setNote(null);
                    const r = await resolveAllRan(periodId);
                    if (!r.ok) { setNote(r.error ?? "Could not resolve all."); return; }
                    setNote(`Resolved ${r.resolved} as ran. Press Close again.`);
                  })}
                  className="rounded-full border border-line-2 bg-surface px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-60">
                  {allPending ? "Resolving…" : "Resolve all as ran"}
                </button>
              </div>
              <ul className="mt-1.5">
                {state.held.map((h) => <HeldRow key={h.occurrence_id} h={h} periodId={periodId} onDone={bump} />)}
              </ul>
              {note && <p className="mt-2 text-[12px]" style={{ color: "var(--lime-text)" }}>{note}</p>}
            </>
          )}
        </div>
      )}
      {state?.ok && <p className="mt-2 text-[13px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>}
    </div>
  );
}
