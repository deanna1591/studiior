"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveSuspension, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

function Num({ name, label, value, min, max, suffix, w = "w-20" }: {
  name: string; label: string; value: number; min?: number; max?: number;
  suffix?: string; w?: string;
}) {
  return (
    <label className="text-[13px] leading-[20px] text-ink-2">
      <span className="mb-1 block">{label}</span>
      <span className="flex items-baseline gap-1.5">
        <input name={name} type="number" min={min} max={max} required
               defaultValue={value} className={`${inputClass} ${w}`} />
        {suffix && <span className="text-[12px] text-ink-3">{suffix}</span>}
      </span>
    </label>
  );
}

/**
 * Decision 24's third switch, and the six numbers behind it.
 *
 * ALL SIX ARE HERE because a column with a default and no way to change it is
 * this project's most repeated bug — `occurrence_horizon_days` left one studio
 * carrying 1,421 classes nobody had agreed to teach. `scripts/audit-settings-ui.py`
 * caught this panel's absence the first time it was run after the migration, and
 * caught that `suspension_enabled` itself had no control: the feature had shipped
 * with no way for a studio to turn it on.
 *
 * The numbers only appear when the switch is on. A threshold that does nothing is
 * worse than one that is missing.
 */
export default function SuspensionPanel({ s, suspendedNow }: {
  s: {
    suspension_enabled: boolean; suspension_window_days: number;
    suspension_warn_at: number; suspension_at: number;
    suspension_days: number; suspension_repeat_days: number;
    peak_cutoff_reminder_minutes: number;
  };
  suspendedNow: number;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveSuspension, null);
  const [on, setOn] = useState(s.suspension_enabled);

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="suspension_enabled" defaultChecked={s.suspension_enabled}
                 onChange={(e) => setOn(e.currentTarget.checked)} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Suspend repeat offenders</span> — repeated
            late cancellations and no-shows stop a member booking ahead.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              They can still take a place on the day, on whatever is free, and their
              membership is billed as normal throughout. A suspension is not a refund,
              and the member app says so.
            </span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Turning this on also starts marking absentees: a class that has finished
              with nobody checked in becomes a no-show. Nothing does that today.
            </span>
          </span>
        </label>

        {on && (
          <div className="mt-3 flex flex-wrap items-end gap-4 border-t border-line pt-3">
            <Num name="suspension_window_days" label="Counted over" value={s.suspension_window_days}
                 min={1} max={365} suffix="days, rolling" />
            <Num name="suspension_warn_at" label="Warn at the" value={s.suspension_warn_at}
                 min={1} max={20} suffix="th" />
            <Num name="suspension_at" label="Suspend at the" value={s.suspension_at}
                 min={2} max={20} suffix="th" />
            <Num name="suspension_days" label="First suspension" value={s.suspension_days}
                 min={1} max={365} suffix="days" />
            <Num name="suspension_repeat_days" label="Each one after" value={s.suspension_repeat_days}
                 min={1} max={365} suffix="days" />
            <p className="w-full max-w-[60ch] text-[12px] leading-[18px] text-ink-3">
              Rolling rather than per month: two in late January and one in early
              February is three in a row, and a calendar boundary would forgive it.
              Each suspension runs from the date of the infraction that caused it.
              {suspendedNow > 0 && (
                <>
                  {" "}
                  <span className="num text-ink">{suspendedNow}</span> member
                  {suspendedNow === 1 ? " is" : "s are"} suspended right now — changing
                  these numbers changes that immediately, because it is worked out
                  rather than stored.
                </>
              )}
            </p>
          </div>
        )}
      </div>

      <div className="mt-4 rounded border border-line bg-surface px-3.5 py-3">
        <Num name="peak_cutoff_reminder_minutes" label="Remind a member holding a peak class"
             value={s.peak_cutoff_reminder_minutes} min={0} max={2880}
             suffix="minutes before free cancellation closes" w="w-24" />
        <p className="mt-2 max-w-[60ch] text-[12px] leading-[18px] text-ink-3">
          The one message worth sending: at that moment cancelling costs them nothing
          and gives you a seat you can still fill. Nought switches it off without
          switching peak hours off, and it only reaches members whose booking has
          actually spent a peak class.
        </p>
      </div>

      <div className="mt-3"><Save /></div>
    </form>
  );
}
