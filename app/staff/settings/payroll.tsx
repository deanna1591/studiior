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
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/**
 * How often instructors are paid, and when. Weekly/fortnightly count fixed days
 * from an anchor; monthly is the calendar month; twice-monthly splits at the 1st
 * and a day you choose. The settle rule (Decision 31) is one of three shapes.
 */
export default function PayrollPanel(
  { mode, secondDay, settleDow, settleOffset, anchor }:
  { mode: string; secondDay: number; settleDow: number | null; settleOffset: number | null; anchor: string | null },
) {
  const [state, action] = useFormState<PlainState, FormData>(savePayFrequency, null);
  const [m, setM] = useState(mode);
  const [shape, setShape] = useState<"none" | "weekday" | "offset">(
    settleDow !== null ? "weekday" : settleOffset !== null ? "offset" : "none",
  );
  const anchorShown = m === "weekly" || m === "fortnightly";

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

        {/* pay_period_anchor: which day the cycle turns on. Only weekly/fortnightly
            need it — monthly uses the calendar month, twice-monthly the day above. */}
        {anchorShown && (
          <label className="mt-3 block">
            <span className="mb-1 block text-[13px] font-medium text-ink">Cycle anchor</span>
            <input name="pay_period_anchor" type="date" defaultValue={anchor ?? ""} className={field} />
            <span className="mt-1 block text-[12px] text-ink-3">
              The reference date the {m} cycle counts from. Leave blank to use the existing schedule.
            </span>
          </label>
        )}

        {/* Decision 31: the settle rule, one of three shapes. Exactly one is
            stored; the database CHECK refuses both at once. */}
        <fieldset className="mt-4 block border-t border-line pt-4">
          <span className="mb-1 block text-[13px] font-medium text-ink">Payment date</span>
          <select name="settle_shape" value={shape} onChange={(e) => setShape(e.target.value as typeof shape)}
                  className={field}>
            <option value="none">Not set — no payment date shown</option>
            <option value="weekday">A weekday after the period closes</option>
            <option value="offset">A number of days after the period closes</option>
          </select>

          {shape === "weekday" && (
            <select name="pay_settle_dow" defaultValue={settleDow === null ? "5" : String(settleDow)}
                    className={`${field} mt-2`}>
              {DAYS.map((d, i) => <option key={i} value={i}>{d} after close</option>)}
            </select>
          )}

          {shape === "offset" && (
            <div className="mt-2">
              <input name="pay_settle_offset_days" type="number" min={0} max={31}
                     defaultValue={settleOffset ?? 2} className={`${field} w-24`} />
              <span className="ml-2 text-[13px] text-ink-2">days after close</span>
              <span className="mt-1 block text-[12px] text-ink-3">
                0 pays on the close date itself — the tightest promise, but a class stays
                unpaid until its instructor has checked in, so a period cannot close (or
                pay) while a check-in is outstanding. A day or two leaves room to chase
                held records before the pay date.
              </span>
            </div>
          )}
          <span className="mt-2 block text-[12px] text-ink-3">
            The date an instructor’s statement promises. Studiior works out what is owed; it does not move money.
          </span>
        </fieldset>

        <div className="mt-4"><Save /></div>
      </div>
    </form>
  );
}
