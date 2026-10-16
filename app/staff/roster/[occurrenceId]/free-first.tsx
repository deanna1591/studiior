"use client";

import { useFormState } from "react-dom";
import { setFreeFirstOverride, type FreeFirstState } from "../actions";

type State = {
  override: "open" | "closed" | null;
  effectiveOpen: boolean;
  rulesOpen: boolean;
  reason: string | null;   // 'core_only' | 'series' | 'disabled' | null
};

function noteFor(s: State): string {
  if (s.override === "open") return "Opened for this class";
  if (s.override === "closed") return "Closed for this class";
  if (s.effectiveOpen) return "Open by studio rules";
  if (s.reason === "core_only") return "Closed by studio rules (flex class)";
  if (s.reason === "series") return "Closed by studio rules (this recurring class is off)";
  return "Closed by studio rules";
}

/**
 * Decision 30 amendment (b) — "Open to first-timers" for this one class. The
 * checkbox shows the TRUE state (by rules or override). Ticking a rules-closed
 * class writes 'open'; unticking a rules-open class writes 'closed'; the link
 * clears it back to the studio rules. Front desk and up; the DB is the boundary.
 */
export default function FreeFirstCard({ occurrenceId, initial }: { occurrenceId: string; initial: State }) {
  const [res, action] = useFormState<FreeFirstState, FormData>(setFreeFirstOverride, null);

  // The live state is the server action's result once it has run, else the
  // initial server-rendered state.
  const s: State = res?.ok
    ? { override: res.override, effectiveOpen: res.effectiveOpen,
        rulesOpen: res.why === "rules" ? res.effectiveOpen : initial.rulesOpen, reason: initial.reason }
    : initial;

  // Tick → open; untick → closed. (A rules-open class unticked becomes an
  // explicit 'closed'; a rules-closed class ticked becomes an explicit 'open'.)
  const nextValue = s.effectiveOpen ? "closed" : "open";

  return (
    <div className="s-card max-w-md px-4 py-3.5">
      <p className="text-[13px] font-semibold text-ink">Free first classes</p>
      <form action={action} className="mt-2">
        <input type="hidden" name="occurrence_id" value={occurrenceId} />
        <input type="hidden" name="value" value={nextValue} />
        <label className="flex items-center gap-2.5">
          <input type="checkbox" checked={s.effectiveOpen} readOnly
                 onChange={(e) => (e.currentTarget.form as HTMLFormElement).requestSubmit()}
                 className="h-4 w-4" />
          <span className="text-[13px] text-ink">Open to first-timers</span>
        </label>
      </form>
      <p className="mt-1.5 text-[12px] text-ink-2">{noteFor(s)}</p>
      {s.override !== null && (
        <form action={action} className="mt-1">
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <input type="hidden" name="value" value="" />
          <button className="text-[12px] text-lime-text underline underline-offset-2">Follow studio rules</button>
        </form>
      )}
      {res && !res.ok && <p className="mt-1 text-[12px]" style={{ color: "var(--coral-deep)" }}>{res.message}</p>}
    </div>
  );
}
