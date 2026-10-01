"use client";

import { useState } from "react";
import { clearMonthAssignments } from "./actions";

/**
 * Decision 42a — clear every instructor assignment in a month, from the Publish
 * page. Behind a confirm, because it removes the instructor from every class and
 * withdraws any pending confirmation request. Members are not affected. The tick
 * (on by default) also clears the recurring classes' own instructor so future
 * months start unassigned — existing occurrences in OTHER months are untouched.
 */
export default function ClearMonthButton({ month, label }: { month: string; label: string }) {
  const [open, setOpen] = useState(false);
  const [clearTemplates, setClearTemplates] = useState(true);

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
      <p className="text-[13px] leading-[19px] text-ink">
        This removes the instructor from every class in <span className="font-medium">{label}</span> and
        withdraws any pending confirmation requests. Members are not affected. You can&rsquo;t undo this.
      </p>
      <label className="mt-2.5 flex items-start gap-2 text-[12.5px] leading-[18px] text-ink-2">
        <input type="checkbox" name="clear_templates" checked={clearTemplates}
               onChange={(e) => setClearTemplates(e.target.checked)} className="mt-0.5" />
        <span>
          Also remove the instructor from the recurring classes themselves, so future months
          start unassigned. Classes already on the calendar in other months keep their instructor.
        </span>
      </label>
      <div className="mt-3 flex items-center gap-2">
        <button className="rounded-lg border bg-coral-tint px-3 py-1.5 text-[12.5px] font-medium text-ink"
                style={{ borderColor: "var(--coral)" }}>
          Clear {label}
        </button>
        <button type="button" onClick={() => setOpen(false)}
                className="text-[12px] text-ink-3 hover:text-ink">Cancel</button>
      </div>
    </form>
  );
}
