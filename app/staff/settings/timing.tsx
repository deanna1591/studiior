"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveTiming, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

export default function TimingPanel({
  dueDay, escalateDays,
}: { dueDay: number; escalateDays: number }) {
  const [state, action] = useFormState<PlainState, FormData>(saveTiming, null);
  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
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
