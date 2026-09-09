"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, inputClass } from "@/components/ui";
import { previewHorizon, applyHorizon, type SettingsState } from "./actions";

function Submit({ label, busy }: { label: string; busy: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? busy : label}</button>;
}

/**
 * How far ahead the timetable runs.
 *
 * Preview then apply, because shortening it DELETES classes. The preview is the
 * point: a number in a box that quietly removed four hundred classes when you
 * pressed save would be the worst control in the product.
 */
export default function HorizonPanel({
  current, scheduled, furthest,
}: { current: number; scheduled: number; furthest: string | null }) {
  const [days, setDays] = useState(current);
  const [previewState, doPreview] = useFormState<SettingsState, FormData>(previewHorizon, null);
  const [applyState, doApply] = useFormState<SettingsState, FormData>(applyHorizon, null);
  const shown = applyState ?? previewState;
  const applied = applyState !== null;

  return (
    <div className="max-w-xl">
      <p className="mb-4 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
        Recurring classes are materialised this far ahead and topped up every
        night. Right now <span className="num text-ink">{scheduled}</span> classes are on
        the calendar{furthest && <>, the last on <span className="num text-ink">{furthest}</span></>}.
        Sixty days is this month and the next — how most studios plan, and the
        month the availability cycle collects for.
      </p>

      {shown && "error" in shown && <Notice kind="error">{shown.error}</Notice>}

      <form action={doPreview} className="flex flex-wrap items-end gap-3">
        <label className="text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">Days ahead</span>
          <input name="days" type="number" min={7} max={730} required value={days}
                 onChange={(e) => setDays(Number(e.target.value))}
                 className={`${inputClass} w-28`} />
        </label>
        <Submit label="See what changes" busy="Working it out…" />
      </form>
      <p className="mt-2 max-w-[58ch] text-[12px] leading-[18px] text-ink-3">
        Between 7 and 730. Shortening it removes classes beyond the new edge —
        you will see exactly how many before anything happens.
      </p>

      {shown && "result" in shown && (
        <Outcome result={shown.result} applied={applied} apply={doApply} />
      )}
    </div>
  );
}

function Outcome({
  result, applied, apply,
}: {
  result: Extract<SettingsState, { result: unknown }>["result"];
  applied: boolean;
  apply: (fd: FormData) => void;
}) {
  if (!result.ok && "reason" in result) {
    return (
      <section className="mt-6 rounded border border-coral bg-coral-tint px-3.5 py-3">
        <p className="text-[13px] leading-[19px] text-ink">
          {result.blocked.length}{" "}
          {result.blocked.length === 1 ? "class has" : "classes have"} members booked
          beyond {result.cutoff}. Nothing has been changed. {result.hint}
        </p>
        <ul className="mt-2 space-y-1">
          {result.blocked.map((b) => (
            <li key={b.occurrence_id} className="text-[13px] leading-[19px] text-ink-2">
              {b.name} — {b.local} — <span className="num">{b.booked}</span> booked
            </li>
          ))}
        </ul>
      </section>
    );
  }

  const kept = result.kept_edited + result.kept_manual;

  return (
    <section className="mt-6 rounded border border-line bg-surface px-3.5 py-3">
      <p className="section-label text-ink-2">{applied ? "What happened" : "What this will do"}</p>
      {result.ok ? (
        <p className="mt-1.5 text-[13px] leading-[19px] text-ink">
          The timetable now runs to {result.cutoff}.{" "}
          {result.deleted > 0 && <>{result.deleted} classes beyond it were removed. </>}
          {result.created > 0 && <>{result.created} were added. </>}
          {result.deleted === 0 && result.created === 0 && <>Nothing on the calendar changed. </>}
        </p>
      ) : (
        <p className="mt-1.5 text-[13px] leading-[19px] text-ink">
          The timetable would run to {result.cutoff}.{" "}
          {result.will_delete > 0
            ? `${result.will_delete} classes beyond it would be removed — deleted, not cancelled, so lengthening it again refills the calendar.`
            : "Nothing would be removed."}
        </p>
      )}
      {kept > 0 && (
        <p className="mt-2 text-[13px] leading-[19px] text-ink-2">
          {result.kept_edited > 0 && <>{result.kept_edited} you have already moved </>}
          {result.kept_edited > 0 && result.kept_manual > 0 && <>and </>}
          {result.kept_manual > 0 && <>{result.kept_manual} you assigned an instructor to </>}
          {kept === 1 ? "is" : "are"} kept — those are decisions somebody made, so a
          setting does not undo them.
        </p>
      )}
      {!applied && (
        <div className="mt-3">
          <form action={apply}>
            {/* The number the PREVIEW used, carried back — not whatever is in
                the box now. Reading it from two places is how a preview of 60
                days and an apply of 365 can differ, which is exactly what
                driving this screen produced. */}
            <input type="hidden" name="days" value={result.days} />
            <Submit label={`Apply ${result.days} days`} busy="Applying…" />
          </form>
        </div>
      )}
    </section>
  );
}
