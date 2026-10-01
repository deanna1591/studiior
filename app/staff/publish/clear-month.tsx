"use client";

import { useState } from "react";
import { clearMonthAssignments } from "./actions";

/**
 * Decision 42a — clear every instructor assignment in a month, from the Publish
 * page. Behind a confirm, because it removes the instructor from every class and
 * withdraws any pending confirmation request. Members are not affected. The tick
 * (on by default) also clears the recurring classes' own instructor so future
 * months start unassigned — existing occurrences in OTHER months are untouched.
 *
 * Amendment: on a PUBLISHED month that members have booked into, an OWNER may
 * still clear it, but only after acknowledging that members' bookings are not
 * touched (every class just becomes an open shift). The acknowledge tick gates
 * the button; `members`/`classes` name N and M in the sentence. A manager never
 * reaches this variant — the page shows them the refusal instead.
 */
export default function ClearMonthButton({
  month, label, members, classes,
}: {
  month: string; label: string;
  members?: number; classes?: number;   // present only on the published+bookings owner variant
}) {
  const needAck = members !== undefined;
  const [open, setOpen] = useState(false);
  const [clearTemplates, setClearTemplates] = useState(true);
  const [acknowledged, setAcknowledged] = useState(false);

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
              className="text-[12.5px] text-ink-2 underline underline-offset-4 hover:text-ink">
        Clear all instructor assignments for this month
      </button>
    );
  }
  return (
    <form action={clearMonthAssignments} className="max-w-[60ch]">
      <input type="hidden" name="month" value={month} />
      {needAck ? (
        <>
          <p className="text-[13px] leading-[19px] text-ink">
            This month is published and <span className="num font-medium">{members}</span>{" "}
            {members === 1 ? "member has" : "members have"} booked into{" "}
            <span className="num font-medium">{classes}</span>{" "}
            {classes === 1 ? "class" : "classes"}. Their bookings stay exactly as they are;
            every class becomes an open shift until you assign it. Members are not told.
          </p>
          <label className="mt-2.5 flex items-start gap-2 text-[12.5px] leading-[18px] text-ink">
            <input type="checkbox" name="acknowledge" checked={acknowledged}
                   onChange={(e) => setAcknowledged(e.target.checked)} className="mt-0.5" />
            <span>I understand — members&rsquo; bookings are not affected</span>
          </label>
        </>
      ) : (
        <p className="text-[13px] leading-[19px] text-ink">
          This removes the instructor from every class in <span className="font-medium">{label}</span> and
          withdraws any pending confirmation requests. Members are not affected. You can&rsquo;t undo this.
        </p>
      )}
      <label className="mt-2.5 flex items-start gap-2 text-[12.5px] leading-[18px] text-ink-2">
        <input type="checkbox" name="clear_templates" checked={clearTemplates}
               onChange={(e) => setClearTemplates(e.target.checked)} className="mt-0.5" />
        <span>
          Also remove the instructor from the recurring classes themselves, so future months
          start unassigned. Classes already on the calendar in other months keep their instructor.
        </span>
      </label>
      <div className="mt-3 flex items-center gap-2">
        <button disabled={needAck && !acknowledged}
                className="rounded-lg border bg-coral-tint px-3 py-1.5 text-[12.5px] font-medium text-ink disabled:cursor-not-allowed disabled:opacity-50"
                style={{ borderColor: "var(--coral)" }}>
          Clear {label}
        </button>
        <button type="button" onClick={() => setOpen(false)}
                className="text-[12px] text-ink-3 hover:text-ink">Cancel</button>
      </div>
    </form>
  );
}
