"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { haptic } from "@/lib/haptics";
import { Note, accentFill } from "@/components/member/ui";
import { submitMyAvailability, type InstructorState } from "@/app/member/instructor/actions";
import { DAY_NAMES, emptyWeek, type Day, type Range } from "@/lib/availability";

/**
 * The month ahead, entered on a phone (Decision 45).
 *
 * Seven day cards, a bottom sheet per day, and the whole week posted as ONE
 * payload — the same shape and the same `submit_availability` the desktop
 * editor uses, because a half-applied week silently changes who the scheduler
 * thinks can teach. Copy-a-day lives in the sheet, because a studio's
 * instructor teaches the same two ranges most weekdays and typing them seven
 * times is how somebody decides not to bother.
 *
 * Nothing is saved until the sticky bar. The sheet is the member app's own
 * `m-sheet` furniture, driven by state rather than the intercepting-route
 * <Sheet> — this is one long-lived client form, not a URL to step back out of.
 */
export default function PhoneAvailabilityEditor({
  instructorId, periodStart, initial, status, locked,
}: {
  instructorId: string;
  periodStart: string;
  initial: Day[];
  status: string;
  locked: boolean;
}) {
  const [days, setDays] = useState<Day[]>(() => emptyWeek(initial));
  const [open, setOpen] = useState<number | null>(null);
  const [state, run] = useFormState<InstructorState, FormData>(submitMyAvailability, null);

  const ranges = (d: number) => days.find((x) => x.day === d)?.ranges ?? [];
  const setRanges = (d: number, fn: (r: Range[]) => Range[]) =>
    setDays((prev) => prev.map((x) => (x.day === d ? { ...x, ranges: fn(x.ranges) } : x)));

  const err = state && "error" in state ? state.error : null;
  const ok = state && "ok" in state ? state.ok : null;

  return (
    <form action={run}>
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="period_start" value={periodStart} />
      <input type="hidden" name="days" value={JSON.stringify(days)} />

      {err && <Note ok={false}>{err}</Note>}
      {ok && <Note ok>{ok}</Note>}

      <ul className="space-y-2">
        {days.map((d) => {
          const rs = d.ranges;
          const inner = (
            <>
              <span className="w-[92px] shrink-0 text-[15px] leading-6 text-ink">
                {DAY_NAMES[d.day]}
              </span>
              <span className="m-sub min-w-0 flex-1 text-ink-2">
                {rs.length === 0
                  ? <span className="text-ink-3">Not available</span>
                  : rs.map((r, i) => (
                      <span key={i} className="num">{i > 0 && ", "}{r.from}–{r.to}</span>
                    ))}
              </span>
              {!locked && <span aria-hidden className="shrink-0 text-ink-3">›</span>}
            </>
          );
          return (
            <li key={d.day}>
              {locked ? (
                <div className="m-card flex items-baseline gap-3 px-4 py-3">{inner}</div>
              ) : (
                <button
                  type="button"
                  onClick={() => { haptic("tap"); setOpen(d.day); }}
                  className="m-card m-press flex w-full items-baseline gap-3 px-4 py-3 text-left"
                >
                  {inner}
                </button>
              )}
            </li>
          );
        })}
      </ul>

      {/* The sticky bar: nothing is saved until one of these is pressed. Only
          when the month is still editable — an approved month is read-only. */}
      {!locked && (
        <div
          className="sticky bottom-0 -mx-4 mt-6 border-t border-line bg-surface px-4 pt-3"
          style={{ paddingBottom: "calc(12px + env(safe-area-inset-bottom, 0px))" }}
        >
          <div className="flex gap-2">
            <SubmitButton value="0" kind="draft">Save draft</SubmitButton>
            <SubmitButton value="1" kind="send">Send to studio</SubmitButton>
          </div>
        </div>
      )}

      {open !== null && (
        <DaySheet
          day={open}
          ranges={ranges(open)}
          otherDays={days.filter((x) => x.day !== open)}
          onClose={() => setOpen(null)}
          onAdd={() =>
            setRanges(open, (rs) => [...rs,
              rs.length ? { from: "13:00", to: "17:00" } : { from: "09:00", to: "12:00" }])}
          onEdit={(i, field, v) =>
            setRanges(open, (rs) => rs.map((x, j) => (j === i ? { ...x, [field]: v } : x)))}
          onRemove={(i) => setRanges(open, (rs) => rs.filter((_, j) => j !== i))}
          onToggleAway={(away) =>
            setRanges(open, (rs) => (away ? [] : rs.length ? rs : [{ from: "09:00", to: "12:00" }]))}
          onCopy={(targets) =>
            setDays((prev) => {
              const src = prev.find((x) => x.day === open)?.ranges ?? [];
              return prev.map((x) =>
                targets.includes(x.day) ? { ...x, ranges: src.map((r) => ({ ...r })) } : x);
            })}
        />
      )}
    </form>
  );
}

function SubmitButton({
  value, kind, children,
}: { value: string; kind: "draft" | "send"; children: React.ReactNode }) {
  const { pending } = useFormStatus();
  const send = kind === "send";
  return (
    <button
      name="submit"
      value={value}
      disabled={pending}
      onClick={() => haptic("tap")}
      style={send ? accentFill : { background: "var(--accent-chip)", color: "var(--ink)" }}
      className={`m-action m-press flex-1 rounded-xl px-4 text-[15px] font-semibold disabled:opacity-60 ${
        send ? "" : ""
      }`}
    >
      {pending ? "One moment…" : children}
    </button>
  );
}

/**
 * The per-day sheet. Rises from the bottom over a scrim; the scrim, the Done
 * button and Escape all close it. Everything it does is on the parent's state —
 * closing it saves nothing on its own, the sticky bar does.
 */
function DaySheet({
  day, ranges, otherDays, onClose, onAdd, onEdit, onRemove, onToggleAway, onCopy,
}: {
  day: number;
  ranges: Range[];
  otherDays: Day[];
  onClose: () => void;
  onAdd: () => void;
  onEdit: (i: number, field: "from" | "to", v: string) => void;
  onRemove: (i: number) => void;
  onToggleAway: (away: boolean) => void;
  onCopy: (targets: number[]) => void;
}) {
  const [copyTo, setCopyTo] = useState<number[]>([]);
  const away = ranges.length === 0;

  return (
    <div>
      <div className="m-sheet-scrim" onClick={onClose} aria-hidden />
      <div role="dialog" aria-modal="true" aria-label={`${DAY_NAMES[day]} availability`} className="m-sheet">
        <div className="m-sheet-grab" aria-hidden />
        <div className="flex items-center justify-between px-4 pt-2">
          <p className="text-[17px] font-semibold text-ink">{DAY_NAMES[day]}</p>
          <button
            type="button" onClick={onClose}
            className="m-press flex h-9 items-center rounded-full px-3 text-[13px] font-semibold text-ink-2"
          >
            Done
          </button>
        </div>

        <div className="m-sheet-body px-4 pb-6">
          {/* Not-available toggle. Checked clears the day; unchecking a cleared
              day seeds one range so there is something to edit. */}
          <label className="mt-2 flex items-center justify-between rounded-xl border border-line-2 px-3.5 py-3">
            <span className="text-[15px] text-ink">Not available this day</span>
            <input
              type="checkbox" checked={away}
              onChange={(e) => onToggleAway(e.target.checked)}
              className="h-5 w-5 accent-[var(--accent-solid)]"
            />
          </label>

          {!away && (
            <ul className="mt-3 space-y-2">
              {ranges.map((r, i) => (
                <li key={i} className="flex items-center gap-2">
                  <input
                    type="time" step={900} value={r.from}
                    aria-label={`${DAY_NAMES[day]} range ${i + 1} starts`}
                    onChange={(e) => onEdit(i, "from", e.target.value)}
                    className="num flex-1 rounded-lg border border-line-2 bg-surface px-3 py-2.5 text-[15px] text-ink"
                  />
                  <span aria-hidden className="text-ink-3">–</span>
                  <input
                    type="time" step={900} value={r.to}
                    aria-label={`${DAY_NAMES[day]} range ${i + 1} ends`}
                    onChange={(e) => onEdit(i, "to", e.target.value)}
                    className="num flex-1 rounded-lg border border-line-2 bg-surface px-3 py-2.5 text-[15px] text-ink"
                  />
                  <button
                    type="button" aria-label={`Remove ${DAY_NAMES[day]} range ${i + 1}`}
                    onClick={() => onRemove(i)}
                    className="m-press flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-[18px] leading-none text-ink-3"
                  >
                    ×
                  </button>
                </li>
              ))}
            </ul>
          )}

          {!away && (
            <button
              type="button" onClick={onAdd}
              className="m-press mt-3 w-full rounded-xl border border-line-2 px-4 py-2.5 text-[14px] font-medium text-ink-2"
            >
              + Add another range
            </button>
          )}

          {/* Copy this day's hours to others — the control that makes the whole
              thing usable. Copying REPLACES, so a day with hours already on it
              says so. */}
          {!away && ranges.length > 0 && (
            <div className="mt-5 border-t border-line pt-4">
              <p className="text-[13px] leading-5 text-ink-2">Copy these hours to:</p>
              <div className="mt-2 flex flex-wrap gap-1.5">
                {otherDays.map((x) => {
                  const on = copyTo.includes(x.day);
                  return (
                    <button
                      key={x.day} type="button" aria-pressed={on}
                      onClick={() => setCopyTo((p) =>
                        p.includes(x.day) ? p.filter((y) => y !== x.day) : [...p, x.day])}
                      className="rounded-full border px-3 py-1.5 text-[13px]"
                      style={on
                        ? { borderColor: "var(--accent-solid)", background: "var(--accent-chip)", color: "var(--ink)" }
                        : { borderColor: "var(--line-2)", color: "var(--ink-2)" }}
                    >
                      {DAY_NAMES[x.day].slice(0, 3)}
                      {x.ranges.length > 0 && <span className="text-ink-3"> · replaces {x.ranges.length}</span>}
                    </button>
                  );
                })}
              </div>
              <button
                type="button"
                disabled={copyTo.length === 0}
                onClick={() => { onCopy(copyTo); setCopyTo([]); }}
                style={accentFill}
                className="m-press mt-3 w-full rounded-xl px-4 py-2.5 text-[14px] font-semibold disabled:opacity-50"
              >
                Copy to {copyTo.length || "…"} day{copyTo.length === 1 ? "" : "s"}
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
