"use client";

import { useState } from "react";
import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, buttonQuietClass } from "@/components/ui";
import { assignInstructor, republishShift, type AssignState, type RepublishState } from "./actions";

export type Candidate = {
  id: string;
  display_name: string;
  /** Down to teach this class type. */
  qualified: boolean;
  /** Says they are around at this time. Context, never a filter — Decision 9. */
  free: boolean;
};

function AssignBtn() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Assigning…" : "Assign"}</button>;
}

function OpenBtn() {
  const { pending } = useFormStatus();
  return (
    <button className={buttonQuietClass} disabled={pending}>
      {pending ? "…" : "Email qualified instructors again"}
    </button>
  );
}

/**
 * Assign somebody to an unstaffed class, or put it back out to instructors —
 * from the class itself, so a gap can be filled without dragging it in day view
 * (the only way there was, and undiscoverable).
 *
 * The dropdown is the cover board's ordering: qualified AND available first, the
 * rest behind "show all" — and the rest are LABELLED, not hidden. "Outside the
 * hours they gave us" is Decision 9's warning, a thing a person may override
 * knowing why, so those instructors are offered with the label rather than
 * removed. Assigning goes through move_occurrence(), which is the wall — it
 * refuses somebody outside the dates they agreed to, and names any clash.
 */
export default function AssignShift({
  occurrenceId, candidates, pendingApplications,
}: {
  occurrenceId: string;
  candidates: Candidate[];
  pendingApplications: number;
}) {
  const [assignState, assign] = useFormState<AssignState, FormData>(assignInstructor, null);
  const [republishState, republish] = useFormState<RepublishState, FormData>(republishShift, null);

  const primary = candidates.filter((c) => c.qualified && c.free);
  const rest = candidates.filter((c) => !(c.qualified && c.free));
  // If nobody is both qualified and free, the primary list is empty and hiding
  // the rest would leave an empty dropdown — so open it up and say why.
  const [showAll, setShowAll] = useState(primary.length === 0);

  const label = (c: Candidate) => {
    const bits: string[] = [];
    if (!c.qualified) bits.push("not down to teach this");
    if (!c.free) bits.push("outside the hours they gave us");
    return bits.length ? ` — ${bits.join(", ")}` : "";
  };

  if (assignState?.ok) {
    return <Notice kind="ok">{assignState.message}</Notice>;
  }

  return (
    <div className="mb-5 rounded border border-line bg-surface px-3.5 py-3">
      <p className="text-[13px] leading-[19px] text-ink">
        <span className="font-medium">Nobody is teaching this class.</span> It is open —
        qualified instructors have been emailed and can apply
        {pendingApplications > 0 ? (
          <>
            , and{" "}
            <Link href="/shifts/applications" className="underline underline-offset-4">
              <span className="num">{pendingApplications}</span>{" "}
              {pendingApplications === 1 ? "has" : "have"} applied
            </Link>
          </>
        ) : null}
        . Assign someone now, or put it out again.
      </p>

      {(assignState && !assignState.ok) && (
        <div className="mt-2.5"><Notice kind="error">{assignState.message}</Notice></div>
      )}

      <form action={assign} className="mt-3 flex flex-wrap items-center gap-2">
        <input type="hidden" name="occurrence_id" value={occurrenceId} />
        <select name="instructor_id" defaultValue="" aria-label="Who is teaching it"
                className="rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink">
          <option value="">Assign someone…</option>
          {primary.length > 0 && (
            <optgroup label="Qualified and available">
              {primary.map((c) => (
                <option key={c.id} value={c.id}>{c.display_name}</option>
              ))}
            </optgroup>
          )}
          {showAll && rest.length > 0 && (
            <optgroup label="Everyone else">
              {rest.map((c) => (
                <option key={c.id} value={c.id}>{c.display_name}{label(c)}</option>
              ))}
            </optgroup>
          )}
        </select>
        <AssignBtn />
        {!showAll && rest.length > 0 && (
          <button type="button" onClick={() => setShowAll(true)}
                  className="text-[12px] text-ink-3 underline underline-offset-4 hover:text-ink">
            Show all {candidates.length}
          </button>
        )}
      </form>

      {candidates.length === 0 && (
        <p className="mt-2 text-[12px] leading-[18px] text-ink-2">
          No instructor is working on this date, so there is nobody to assign
          directly. Put it out to instructors instead.
        </p>
      )}

      <div className="mt-3 border-t border-line pt-3">
        {republishState && (
          <div className="mb-2"><Notice kind={republishState.ok ? "ok" : "error"}>{republishState.message}</Notice></div>
        )}
        <form action={republish} className="flex flex-wrap items-center gap-2">
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <OpenBtn />
          <span className="text-[12px] leading-[18px] text-ink-3">
            It is already open; this asks qualified instructors again.
          </span>
        </form>
      </div>
    </div>
  );
}
