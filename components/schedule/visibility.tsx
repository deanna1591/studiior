"use client";

import { useEffect, useRef } from "react";
import { useFormState } from "react-dom";
import { setVisibility, type VisibilityState } from "@/app/staff/roster/actions";

/**
 * Decision 91 — the "Visible to members" switch in the Schedule class popup. On
 * by default. Off takes the class off the member side (Book tab, public
 * timetable, nudges, new bookings) without cancelling it; a member already
 * booked keeps it. Owners and managers only (the DB is the boundary). Switching
 * OFF a core class confirms with the line that it still runs and pays the
 * instructor. The popup stays open across a change (useFormState re-renders),
 * and onChange tells the calendar so the "Hidden" chip updates.
 */
export default function VisibilityCard({ occurrenceId, hidden: initialHidden, isCore, onChange }: {
  occurrenceId: string;
  hidden: boolean;
  isCore: boolean;
  onChange?: (hidden: boolean) => void;
}) {
  const [res, action] = useFormState<VisibilityState, FormData>(setVisibility, null);
  const hidden = res?.ok ? res.hidden : initialHidden;
  const visible = !hidden;
  const formRef = useRef<HTMLFormElement>(null);

  const sent = useRef<boolean | null>(null);
  useEffect(() => {
    if (!res?.ok) return;
    if (sent.current !== res.hidden) { sent.current = res.hidden; onChange?.(res.hidden); }
  }, [res, onChange]);

  return (
    <section className="mt-4 rounded border border-line bg-surface px-3.5 py-3">
      {res && !res.ok && <p className="mb-2 text-[12.5px] text-coral">{res.message}</p>}
      <form action={action} ref={formRef}>
        <input type="hidden" name="occurrence_id" value={occurrenceId} />
        {/* The action posts the NEW value — the opposite of the current one. */}
        <input type="hidden" name="visible" value={visible ? "0" : "1"} />
        <label className="flex items-center justify-between gap-3">
          <span className="text-[13px] font-medium leading-[19px] text-ink">Visible to members</span>
          <input
            type="checkbox"
            checked={visible}
            className="h-4 w-4"
            onChange={(e) => {
              // Switching OFF a core class: confirm with the line that it still
              // runs and pays the instructor (Decision 91).
              if (!e.target.checked && isCore &&
                  !window.confirm("This class is core. It will still run and pay the instructor even if nobody books.")) {
                return;
              }
              formRef.current?.requestSubmit();
            }}
          />
        </label>
      </form>
      {hidden ? (
        <p className="mt-2 text-[12px] leading-[18px] text-ink-3">
          Off the member app, the public timetable and new bookings. Members already
          booked keep their spot and still see it.
        </p>
      ) : isCore ? (
        <p className="mt-2 text-[12px] leading-[18px] text-ink-3">
          This class is core. It will still run and pay the instructor even if nobody books.
        </p>
      ) : null}
    </section>
  );
}
