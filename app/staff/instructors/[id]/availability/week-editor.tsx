"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { saveAvailability, type AvailState } from "./actions";

export type Range = { from: string; to: string };
export type Day = { day: number; ranges: Range[] };

const NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const INITIALS = ["S", "M", "T", "W", "T", "F", "S"];

/**
 * A week of availability, entered in one go.
 *
 * COPY-A-DAY IS THE POINT OF THIS SCREEN. The studio's instructors teach 9-12
 * consecutive classes a week on a fixed pattern, which means most weekdays are
 * the same two ranges — and entering those seven times by hand is how a studio
 * decides not to bother, which leaves instructor_available_at() reading an
 * empty table and every scheduling warning silently meaningless.
 *
 * The copy happens HERE, on the form state, and the whole week posts as one
 * payload. The alternative — a "copy" that writes rows on the server — would
 * make a half-applied week reachable, and a half-applied week quietly changes
 * who the scheduler says can teach.
 */
export default function WeekEditor({
  instructorId, initial, effectiveFrom, effectiveTo, canEdit,
}: {
  instructorId: string;
  initial: Day[];
  effectiveFrom: string | null;
  effectiveTo: string | null;
  canEdit: boolean;
}) {
  const [days, setDays] = useState<Day[]>(() =>
    Array.from({ length: 7 }, (_, d) => initial.find((x) => x.day === d) ?? { day: d, ranges: [] }));
  const [copyFrom, setCopyFrom] = useState<number | null>(null);
  const [copyTo, setCopyTo] = useState<number[]>([]);
  const [state, action] = useFormState<AvailState, FormData>(saveAvailability, null);

  const edit = (d: number, fn: (r: Range[]) => Range[]) =>
    setDays((prev) => prev.map((x) => (x.day === d ? { ...x, ranges: fn(x.ranges) } : x)));

  const applyCopy = () => {
    if (copyFrom === null || copyTo.length === 0) return;
    const src = days.find((x) => x.day === copyFrom)?.ranges ?? [];
    setDays((prev) => prev.map((x) =>
      copyTo.includes(x.day) ? { ...x, ranges: src.map((r) => ({ ...r })) } : x));
    setCopyFrom(null);
    setCopyTo([]);
  };

  return (
    <form action={action}>
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="days" value={JSON.stringify(days)} />
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <ul className="space-y-1">
        {days.map((d) => (
          <li key={d.day} className="flex items-start gap-3 border-b border-line py-3 last:border-0">
            <span
              className="mt-1 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-ink text-[12px] font-semibold text-surface"
              title={NAMES[d.day]}
            >
              {INITIALS[d.day]}
            </span>
            <span className="sr-only">{NAMES[d.day]}</span>

            <div className="min-w-0 flex-1">
              {d.ranges.length === 0 ? (
                <p className="py-1.5 text-[13px] leading-[20px] text-ink-3">Unavailable</p>
              ) : (
                <ul className="space-y-1.5">
                  {d.ranges.map((r, i) => (
                    <li key={i} className="flex items-center gap-2">
                      <input
                        type="time" value={r.from} disabled={!canEdit}
                        aria-label={`${NAMES[d.day]} range ${i + 1} starts`}
                        onChange={(e) => edit(d.day, (rs) =>
                          rs.map((x, j) => (j === i ? { ...x, from: e.target.value } : x)))}
                        className="num w-[132px] rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink"
                      />
                      <span aria-hidden className="text-ink-3">–</span>
                      <input
                        type="time" value={r.to} disabled={!canEdit}
                        aria-label={`${NAMES[d.day]} range ${i + 1} ends`}
                        onChange={(e) => edit(d.day, (rs) =>
                          rs.map((x, j) => (j === i ? { ...x, to: e.target.value } : x)))}
                        className="num w-[132px] rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink"
                      />
                      {canEdit && (
                        <button
                          type="button" aria-label={`Remove ${NAMES[d.day]} range ${i + 1}`}
                          onClick={() => edit(d.day, (rs) => rs.filter((_, j) => j !== i))}
                          className="rounded-md px-1.5 py-1 text-[15px] leading-none text-ink-3 hover:text-ink"
                        >
                          ×
                        </button>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </div>

            {canEdit && (
              <div className="flex shrink-0 items-center gap-1 pt-1">
                <button
                  type="button" aria-label={`Add a time to ${NAMES[d.day]}`}
                  onClick={() => edit(d.day, (rs) => [...rs,
                    rs.length ? { from: "13:00", to: "17:00" } : { from: "09:00", to: "12:00" }])}
                  className="rounded-md border border-line-2 px-2 py-1 text-[13px] leading-none text-ink-2"
                >
                  +
                </button>
                <button
                  type="button"
                  aria-label={`Copy ${NAMES[d.day]} to other days`}
                  onClick={() => { setCopyFrom(copyFrom === d.day ? null : d.day); setCopyTo([]); }}
                  disabled={d.ranges.length === 0}
                  className={`rounded-md border px-2 py-1 text-[12px] leading-none disabled:opacity-40 ${
                    copyFrom === d.day ? "border-lime-text bg-lime-tint text-lime-text"
                                       : "border-line-2 text-ink-2"}`}
                >
                  Copy
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>

      {copyFrom !== null && (
        <div className="mt-3 rounded-xl border border-line-2 bg-paper p-4">
          <p className="text-[13px] leading-[20px] text-ink">
            Copy <strong>{NAMES[copyFrom]}</strong> to:
          </p>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {days.filter((x) => x.day !== copyFrom).map((x) => (
              <button
                key={x.day} type="button"
                aria-pressed={copyTo.includes(x.day)}
                onClick={() => setCopyTo((p) =>
                  p.includes(x.day) ? p.filter((y) => y !== x.day) : [...p, x.day])}
                className={`rounded-full border px-3 py-1.5 text-[13px] ${
                  copyTo.includes(x.day)
                    ? "border-lime-text bg-lime-tint font-medium text-lime-text"
                    : "border-line-2 bg-surface text-ink-2"}`}
              >
                {NAMES[x.day]}
                {/* Said out loud, because copying REPLACES rather than merges
                    and a day with hours already on it is about to lose them. */}
                {x.ranges.length > 0 && <span className="text-ink-3"> · replaces {x.ranges.length}</span>}
              </button>
            ))}
          </div>
          <div className="mt-3 flex gap-2">
            <button type="button" onClick={applyCopy} disabled={copyTo.length === 0}
                    className="rounded-lg bg-lime px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-50">
              Copy to {copyTo.length || "…"} day{copyTo.length === 1 ? "" : "s"}
            </button>
            <button type="button" onClick={() => { setCopyFrom(null); setCopyTo([]); }}
                    className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2">
              Cancel
            </button>
          </div>
        </div>
      )}

      {canEdit && (
        <div className="mt-5 flex flex-wrap items-end gap-4 border-t border-line pt-4">
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">In effect from</span>
            <input type="date" name="effective_from" defaultValue={effectiveFrom ?? ""}
                   className={inputClass} />
          </label>
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">until</span>
            <input type="date" name="effective_to" defaultValue={effectiveTo ?? ""}
                   className={inputClass} />
          </label>
          <Save />
        </div>
      )}
      {canEdit && (
        <p className="mt-2 text-[12px] leading-[18px] text-ink-3">
          Left blank, this pattern is open-ended. It deliberately does not follow
          the commitment below: these dates decide who the scheduler may offer a
          class to, and an agreement reaching its end date must not quietly take
          somebody off the roster. Availability never unassigns anyone from a
          class they have already been given.
        </p>
      )}
    </form>
  );
}

function Save() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-lg bg-lime px-4 py-2 text-[14px] font-medium text-ink disabled:opacity-60">
      {pending ? "Saving…" : "Save the week"}
    </button>
  );
}
