"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveTiming, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

export default function TimingPanel({
  dueDay, escalateDays, weekConfirm, availReminders,
}: { dueDay: number; escalateDays: number; weekConfirm: boolean; availReminders: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveTiming, null);
  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      {/* Both off by default — an instructor at a booking-only studio is not
          asked to confirm a week or submit availability for a workflow the
          studio does not run. */}
      <div className="mb-4 space-y-2">
        <label className="flex items-start gap-2.5 text-[13px] leading-[20px] text-ink">
          <input type="checkbox" name="week_confirm_enabled" defaultChecked={weekConfirm} className="mt-0.5 h-4 w-4" />
          <span>Ask instructors to confirm the week ahead
            <span className="block text-[12px] leading-[17px] text-ink-3">A weekly request to confirm the classes they are down for, with an escalation if it goes unanswered.</span>
          </span>
        </label>
        <label className="flex items-start gap-2.5 text-[13px] leading-[20px] text-ink">
          <input type="checkbox" name="availability_reminders_enabled" defaultChecked={availReminders} className="mt-0.5 h-4 w-4" />
          <span>Remind instructors to submit their availability
            <span className="block text-[12px] leading-[17px] text-ink-3">A monthly nudge before the due day. Instructors can always submit without it; this is the automated reminder.</span>
          </span>
        </label>
      </div>
      <div className="flex flex-wrap items-end gap-4">
        <label className="text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">Availability due on the</span>
          <input name="availability_due_day" type="number" min={1} max={28} required
                 defaultValue={dueDay} className={`${inputClass} w-24`} />
        </label>
        <label className="text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">Escalate unconfirmed classes within</span>
          <input name="week_confirm_escalate_days" type="number" min={1} max={14} required
                 defaultValue={escalateDays} className={`${inputClass} w-24`} />
        </label>
        <Save />
      </div>
      <p className="mt-2 max-w-[58ch] text-[12px] leading-[18px] text-ink-3">
        Next month&rsquo;s availability is due on that day of this month — capped
        at 28 so February has it too. Unconfirmed classes are only reported to you
        when they are that many days away; a Friday class unconfirmed on Sunday is
        not yet a problem.
      </p>
    </form>
  );
}
