"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { savePeakSwitch, addPeakWindow, removePeakWindow, type PlainState } from "./actions";

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

export type Window = {
  id: string; day_of_week: number; starts_at: string; ends_at: string; upcoming: number;
};

function Save({ label = "Save" }: { label?: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

/**
 * Decision 24's second switch, and the grid behind it.
 *
 * THE COUNT BESIDE EACH WINDOW IS THE POINT. A studio drawing 07:00–09:00 on a
 * grid cannot tell from the grid whether that is four classes a week or forty,
 * and a peak window that catches the whole timetable is an allowance that stops
 * everybody booking anything. The number is measured against the classes that
 * are really on the calendar for the next four weeks.
 */
export default function PeakPanel({ enabled, windows, plans }: {
  enabled: boolean;
  windows: Window[];
  /** Plans that carry an allowance, so the panel can say whether any does. */
  plans: { id: string; name: string; peak_allowance: number; peak_allowance_period: string }[];
}) {
  const [state, action] = useFormState<PlainState, FormData>(savePeakSwitch, null);
  const [addState, add] = useFormState<PlainState, FormData>(addPeakWindow, null);

  const byDay = DAYS.map((_, d) => windows.filter((w) => w.day_of_week === d));
  const total = windows.reduce((n, w) => n + w.upcoming, 0);

  return (
    <div className="max-w-2xl">
      <form action={action}>
        {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
        <div className="rounded border border-line bg-surface px-3.5 py-3">
          <label className="flex items-start gap-2.5">
            <input type="checkbox" name="peak_allowance_enabled" defaultChecked={enabled} className="mt-1" />
            <span className="text-[13px] leading-[19px] text-ink">
              <span className="font-medium">Peak hours</span> — mark your busy hours,
              and limit how many of them an unlimited plan may book.
              <span className="block text-[12px] leading-[18px] text-ink-3">
                A class is peak if it <em>starts</em> inside a window. A 16:55 class
                is not peak against a window that opens at 17:00, and neither is a
                19:00 class against one that closes at 19:00.
              </span>
            </span>
          </label>
        </div>
        <div className="mt-3"><Save /></div>
      </form>

      {enabled && (
        <>
          <div className="mt-6 overflow-x-auto">
            <table className="w-full min-w-[34rem] border-collapse text-[13px]">
              <tbody>
                {DAYS.map((name, d) => (
                  <tr key={d} className="border-b border-line align-top">
                    <th scope="row" className="w-28 py-2 pr-3 text-left font-medium text-ink">{name}</th>
                    <td className="py-2">
                      {byDay[d].length === 0 ? (
                        <span className="text-ink-3">Nothing is peak</span>
                      ) : (
                        <span className="flex flex-wrap gap-1.5">
                          {byDay[d].map((w) => (
                            <form key={w.id} action={removePeakWindow}>
                              <input type="hidden" name="id" value={w.id} />
                              <span className="inline-flex items-center gap-1.5 rounded border border-line bg-paper px-2 py-1">
                                <span className="num text-ink">
                                  {w.starts_at.slice(0, 5)}–{w.ends_at.slice(0, 5)}
                                </span>
                                <span className="text-[11px] text-ink-2">
                                  <span className="num">{w.upcoming}</span>{" "}
                                  class{w.upcoming === 1 ? "" : "es"}
                                </span>
                                <button className="text-[11px] text-ink-2 underline underline-offset-2"
                                        aria-label={`Remove ${name} ${w.starts_at.slice(0, 5)}`}>
                                  remove
                                </button>
                              </span>
                            </form>
                          ))}
                        </span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="mt-2 text-[12px] leading-[18px] text-ink-3">
            {total === 0
              ? "None of your classes fall in a peak window yet, so nothing is limited."
              : <><span className="num">{total}</span> of the next four weeks&rsquo; classes fall in a peak window.</>}
          </p>

          <form action={add} className="mt-4 flex flex-wrap items-end gap-2.5">
            {addState && !addState.ok && (
              <div className="w-full"><Notice kind="error">{addState.message}</Notice></div>
            )}
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">Day</span>
              <select name="day_of_week" className={`${inputClass} w-32`} defaultValue="1">
                {DAYS.map((n, d) => <option key={d} value={d}>{n}</option>)}
              </select>
            </label>
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">From</span>
              <input name="starts_at" type="time" required defaultValue="17:00" className={`${inputClass} w-28`} />
            </label>
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">To</span>
              <input name="ends_at" type="time" required defaultValue="19:00" className={`${inputClass} w-28`} />
            </label>
            <label className="flex items-center gap-1.5 pb-2 text-[12px] text-ink-2">
              <input type="checkbox" name="every_day" /> every day
            </label>
            <Save label="Add" />
          </form>

          <p className="mt-4 text-[12px] leading-[18px] text-ink-3">
            {plans.length === 0 ? (
              <>
                No plan is limited to these hours yet, so marking them changes nothing
                for anybody. Set a peak allowance on an unlimited plan to make it bite —
                a plan that includes a number of classes already has that number as its
                limit.
              </>
            ) : (
              <>
                {plans.map((p) => (
                  <span key={p.id} className="mr-2">
                    <span className="text-ink">{p.name}</span>:{" "}
                    <span className="num">{p.peak_allowance}</span> peak class
                    {p.peak_allowance === 1 ? "" : "es"} per {p.peak_allowance_period}.
                  </span>
                ))}
              </>
            )}
          </p>
        </>
      )}
    </div>
  );
}
