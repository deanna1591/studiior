"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveGuarantees, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

function Num({ name, label, value, min, max, suffix, w = "w-24" }: {
  name: string; label: string; value: number | string; min?: number; max?: number;
  suffix?: string; w?: string;
}) {
  return (
    <label className="text-[13px] leading-[20px] text-ink-2">
      <span className="mb-1 block">{label}</span>
      <span className="flex items-baseline gap-1.5">
        <input name={name} type="number" min={min} max={max} step="any" required
               defaultValue={value} className={`${inputClass} ${w}`} />
        {suffix && <span className="text-[12px] text-ink-3">{suffix}</span>}
      </span>
    </label>
  );
}

/**
 * Decision 22's two switches and the settings each one gates.
 *
 * TWO SWITCHES, NOT ONE, and the panel has to show that: `flex_enabled` governs
 * flex and `guarantees_enabled` governs core, so a studio already running flex
 * neither breaks nor silently acquires core evaluation on every other class.
 * Each tier's settings are only shown when its own switch is on — a number that
 * does nothing is worse than one that is missing.
 */
export default function GuaranteesPanel({ s, currency }: {
  s: {
    guarantees_enabled: boolean; flex_enabled: boolean;
    core_min_bookings: number; core_cutoff_hours: number; core_unmet_pay_pct: number;
    flex_min_bookings: number; flex_deadline_mode: string; flex_deadline_time: string;
    flex_deadline_hours: number; flex_unmet_pay_cents: number;
    flex_standby_pay_cents: number; adjacency_minutes: number;
  };
  currency: string;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveGuarantees, null);
  const [core, setCore] = useState(s.guarantees_enabled);
  const [flex, setFlex] = useState(s.flex_enabled);
  const [mode, setMode] = useState(s.flex_deadline_mode ?? "previous_day_at");

  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <p className="mb-4 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        A guarantee decides whether a class runs when few people book it, and what
        the instructor is owed when it does not. Both switches are off until you
        turn them on, and with both off nothing is evaluated and nothing is owed —
        which is how the studio works today.
      </p>

      {/* CORE */}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="guarantees_enabled" defaultChecked={s.guarantees_enabled}
                 onChange={(e) => setCore(e.currentTarget.checked)} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Core classes</span> — a class runs if it
            reaches its minimum by the cutoff. If it does not, it does not run and
            the instructor is paid a holding rate.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              This is the default tier, so turning it on affects every class that
              is not marked flex or always.
            </span>
          </span>
        </label>
        {core && (
          <div className="mt-3 flex flex-wrap items-end gap-4 border-t border-line pt-3">
            <Num name="core_min_bookings" label="Runs at" value={s.core_min_bookings}
                 min={0} max={99} suffix="bookings or more" />
            <Num name="core_cutoff_hours" label="Decided" value={s.core_cutoff_hours}
                 min={0} max={336} suffix="hours before the class" />
            <Num name="core_unmet_pay_pct" label="If it does not run, pay"
                 value={s.core_unmet_pay_pct} min={0} max={100} suffix="% of base" />
            <p className="w-full max-w-[58ch] text-[12px] leading-[18px] text-ink-3">
              Counted back from each class, deliberately: it mirrors the
              cancellation window, and by then the headcount is effectively final.
            </p>
          </div>
        )}
      </div>

      {/* FLEX */}
      <div className="mt-3 rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="flex_enabled" defaultChecked={s.flex_enabled}
                 onChange={(e) => setFlex(e.currentTarget.checked)} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Flex classes</span> — a slot you only run
            if enough people book. If it does not reach its minimum there is no
            obligation and, unless you set one below, no pay.
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Only classes you mark flex on the series. Members are never told a
              class might not run.
            </span>
          </span>
        </label>
        {flex && (
          <div className="mt-3 flex flex-wrap items-end gap-4 border-t border-line pt-3">
            <Num name="flex_min_bookings" label="Runs at" value={s.flex_min_bookings}
                 min={0} max={99} suffix="bookings or more" />
            <label className="text-[13px] leading-[20px] text-ink-2">
              <span className="mb-1 block">Decided</span>
              <select name="flex_deadline_mode" defaultValue={mode}
                      onChange={(e) => setMode(e.currentTarget.value)}
                      className={inputClass}>
                <option value="previous_day_at">at a set time the evening before</option>
                <option value="hours_before">a number of hours before each class</option>
              </select>
            </label>
            {mode === "previous_day_at" ? (
              <label className="text-[13px] leading-[20px] text-ink-2">
                <span className="mb-1 block">at</span>
                <input name="flex_deadline_time" type="time" required
                       defaultValue={(s.flex_deadline_time ?? "20:00").slice(0, 5)}
                       className={`${inputClass} w-32`} />
              </label>
            ) : (
              <Num name="flex_deadline_hours" label="hours before"
                   value={s.flex_deadline_hours} min={0} max={336} />
            )}
            <Num name="flex_unmet_pay" label="If it does not run, pay"
                 value={(s.flex_unmet_pay_cents / 100).toFixed(2)} min={0} suffix={currency} w="w-28" />
            <Num name="flex_standby_pay" label="Standby, if the slot stands alone"
                 value={(s.flex_standby_pay_cents / 100).toFixed(2)} min={0} suffix={currency} w="w-28" />
            <p className="w-full max-w-[62ch] text-[12px] leading-[18px] text-ink-3">
              A fixed time so an instructor can plan a whole day at once, and it
              holds across a clock change — 20:00 stays 20:00. Standby is paid only
              when the slot has nothing else of theirs near it: a flex class beside
              another of their classes costs them nothing extra, one on its own
              cost them the trip.
            </p>
          </div>
        )}
        {/* Hidden so the mode's unused half still posts a value and the column
            keeps whatever it had, rather than being reset to a default. */}
        {flex && mode === "previous_day_at" && (
          <input type="hidden" name="flex_deadline_hours" value={s.flex_deadline_hours} />
        )}
        {flex && mode === "hours_before" && (
          <input type="hidden" name="flex_deadline_time"
                 value={(s.flex_deadline_time ?? "20:00").slice(0, 5)} />
        )}
      </div>

      {/* Values that must post even when a tier's panel is collapsed, or the
          update would write NaN over a setting the studio had chosen. */}
      {!core && (
        <>
          <input type="hidden" name="core_min_bookings" value={s.core_min_bookings} />
          <input type="hidden" name="core_cutoff_hours" value={s.core_cutoff_hours} />
          <input type="hidden" name="core_unmet_pay_pct" value={s.core_unmet_pay_pct} />
        </>
      )}
      {!flex && (
        <>
          <input type="hidden" name="flex_min_bookings" value={s.flex_min_bookings} />
          <input type="hidden" name="flex_deadline_mode" value={s.flex_deadline_mode ?? "previous_day_at"} />
          <input type="hidden" name="flex_deadline_time" value={(s.flex_deadline_time ?? "20:00").slice(0, 5)} />
          <input type="hidden" name="flex_deadline_hours" value={s.flex_deadline_hours} />
          <input type="hidden" name="flex_unmet_pay" value={(s.flex_unmet_pay_cents / 100).toFixed(2)} />
          <input type="hidden" name="flex_standby_pay" value={(s.flex_standby_pay_cents / 100).toFixed(2)} />
        </>
      )}

      <div className="mt-4 flex flex-wrap items-end gap-4">
        <Num name="adjacency_minutes" label="A slot stands alone if nothing else of theirs is within"
             value={s.adjacency_minutes} min={0} max={1440} suffix="minutes" />
        <Save />
      </div>
    </form>
  );
}
