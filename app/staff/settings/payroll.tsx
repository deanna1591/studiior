"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { savePayFrequency, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

/**
 * How often instructors are paid. Weekly and fortnightly count fixed days from an
 * anchor; monthly is the calendar month; twice-monthly splits at the 1st and a
 * day you choose. Changing this only shapes periods created from here on.
 */
export default function PayrollPanel({ mode, secondDay }: { mode: string; secondDay: number }) {
  const [state, action] = useFormState<PlainState, FormData>(savePayFrequency, null);
  const [m, setM] = useState(mode);

  return (
    <form action={action} className="max-w-xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface p-4">
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Pay period</span>
          <select name="pay_period_mode" value={m} onChange={(e) => setM(e.target.value)} className={field}>
            <option value="weekly">Weekly</option>
            <option value="fortnightly">Fortnightly</option>
            <option value="monthly">Monthly (calendar month)</option>
            <option value="semimonthly">Twice a month</option>
          </select>
        </label>
        {m === "semimonthly" && (
          <label className="mt-3 block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Second period starts on day</span>
            <input name="pay_period_second_day" type="number" min={2} max={28} defaultValue={secondDay}
                   className={`${field} w-24`} />
            <span className="mt-1 block text-[12px] text-ink-3">
              The first period is the 1st to the day before; the second runs from this day to month end.
            </span>
          </label>
        )}
        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
