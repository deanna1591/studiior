"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { createFromSlot, type CreateState } from "./create-actions";
import TierField from "@/components/tier-field";
import { fromStudioWall } from "@/lib/tz";

function Add({ repeats }: { repeats: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="m-tap rounded-lg px-3.5 py-2 text-[13px] font-medium disabled:opacity-60"
            style={{ background: "var(--ink)", color: "var(--paper)" }}>
      {pending ? "Adding…" : repeats ? "Create series" : "Add class"}
    </button>
  );
}

/** 0=Sun..6=Sat, react/JS convention, mapped to RRULE day codes and short names. */
const RRULE_DAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] as const;
const SHORT_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
// Displayed Monday-first, which is how a week reads even when the studio's own
// week starts on Sunday — this is only the picker order, not a scheduling fact.
const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

export type SlotDraft = {
  view: "day" | "week" | "month";
  /** Studio-local, from where the click landed. */
  dateKey: string;          // YYYY-MM-DD
  /** Studio-local HH:MM; null on Month, where there is no time on a day cell. */
  timeHHMM: string | null;
  /** 0..6 of the clicked date, to default the repeat day picker. */
  weekday: number;
  /** The drag length in minutes, or null (a single click / a month cell). */
  slotMinutes: number | null;
  /** The clicked instructor column on Day; null on Week/Month (no columns). */
  instructorId: string | null;
  instructorName: string | null;
};

/**
 * Decision 37 — the create panel a slot-click opens, on ANY view.
 *
 * It makes a single class or a weekly series without leaving the calendar, and
 * keeps the WHOLE rule visible: the instructor, the tier, the date and time, and
 * — when "Repeats weekly" is on — the days, the "until" date and a live summary
 * of exactly what one press will make. That visibility is the answer to why
 * migration 089 kept recurring at /series: the surprise was a hidden repeat, not
 * the repeat itself.
 */
export default function CreateOnSlot({
  draft, classTypes, rooms, instructors, coreEnabled, flexEnabled,
  assignmentConfirmations, timeZone, onDone, onCancel,
}: {
  draft: SlotDraft;
  classTypes: { id: string; name: string; duration_minutes: number; default_capacity: number }[];
  rooms: { id: string; name: string; capacity: number }[];
  instructors: { id: string; name: string }[];
  coreEnabled: boolean;
  flexEnabled: boolean;
  assignmentConfirmations: boolean;
  timeZone: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [state, action] = useFormState<CreateState, FormData>(createFromSlot, null);
  const done = useRef(false);
  const seriesOk = state && "ok" in state && state.ok && "seriesId" in state;
  useEffect(() => {
    if (state && "ok" in state && state.ok && !done.current) {
      done.current = true;
      // A series success stays open (it carries a "View series" link); a one-off
      // closes after a beat, longer when there is a warning to read first.
      if ("seriesId" in state) return;
      const t = setTimeout(onDone, state.warnings.length ? 2200 : 700);
      return () => clearTimeout(t);
    }
  }, [state, onDone]);

  const [classTypeId, setClassTypeId] = useState(classTypes[0]?.id ?? "");
  const [instructor, setInstructor] = useState<string>(
    draft.view === "day" ? (draft.instructorId ?? "unassigned") : "");
  const [dateKey, setDateKey] = useState(draft.dateKey);
  const [time, setTime] = useState(draft.timeHHMM ?? "");
  const [repeats, setRepeats] = useState(false);
  const [byday, setByday] = useState<Set<number>>(new Set([draft.weekday]));
  const [until, setUntil] = useState("");

  const selectedType = classTypes.find((c) => c.id === classTypeId) ?? classTypes[0];
  const duration = draft.slotMinutes ?? selectedType?.duration_minutes ?? 50;

  // The one-off instant, computed on THIS side of the timezone boundary exactly
  // as a drag is: a Date whose local fields ARE the studio wall time, converted
  // back to a real instant. Null until date+time are both present.
  const instants = useMemo(() => {
    if (!dateKey || !time) return null;
    const [y, m, d] = dateKey.split("-").map(Number);
    const [hh, mm] = time.split(":").map(Number);
    if ([y, m, d, hh, mm].some((n) => !Number.isFinite(n))) return null;
    const start = fromStudioWall(new Date(y, m - 1, d, hh, mm), timeZone);
    const end = new Date(start.getTime() + duration * 60_000);
    return { start: start.toISOString(), end: end.toISOString() };
  }, [dateKey, time, duration, timeZone]);

  const instructorId = instructor === "unassigned" ? "" : instructor;
  const instructorName =
    instructor === "unassigned" || instructor === "" ? null
    : instructors.find((i) => i.id === instructor)?.name ?? null;

  const rrule = useMemo(() => {
    const days = DAY_ORDER.filter((d) => byday.has(d)).map((d) => RRULE_DAYS[d]);
    return days.length ? `FREQ=WEEKLY;BYDAY=${days.join(",")}` : "";
  }, [byday]);

  // "Every Mon and Thu 07:00 with Rhon until 20 Dec — 24 classes".
  const summary = useMemo(() => {
    if (!repeats) return null;
    const picked = DAY_ORDER.filter((d) => byday.has(d));
    if (!picked.length || !time || !until || until < dateKey) return null;
    const dayNames = picked.map((d) => SHORT_DAYS[d]);
    const daysText = dayNames.length === 1 ? dayNames[0]
      : `${dayNames.slice(0, -1).join(", ")} and ${dayNames[dayNames.length - 1]}`;
    // Count the dates from start to "until" whose weekday is selected — the same
    // rule the generator applies (weekly, on those days, up to the end date).
    let count = 0;
    const [sy, sm, sd] = dateKey.split("-").map(Number);
    const [uy, um, ud] = until.split("-").map(Number);
    const cur = new Date(Date.UTC(sy, sm - 1, sd));
    const end = new Date(Date.UTC(uy, um - 1, ud));
    let guard = 0;
    while (cur <= end && guard++ < 800) {
      if (byday.has(cur.getUTCDay())) count++;
      cur.setUTCDate(cur.getUTCDate() + 1);
    }
    const untilWord = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" })
      .format(new Date(Date.UTC(uy, um - 1, ud, 12)));
    const withWhom = instructorName ? `with ${instructorName}` : "unassigned";
    return `Every ${daysText} ${time} ${withWhom} until ${untilWord} — ${count} ${count === 1 ? "class" : "classes"}`;
  }, [repeats, byday, time, until, dateKey, instructorName]);

  const needRoom = state && !state.ok && "needRoom" in state;
  const blocked = state && !state.ok && "blockedBy" in state ? state.blockedBy : undefined;
  const roomOptions = needRoom && "rooms" in state ? state.rooms : rooms;
  const askRoom = needRoom || rooms.length > 1;

  const fieldCls = "w-full rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink";

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/20 p-4 sm:items-center"
         role="dialog" aria-modal="true" aria-label="Add a class">
      <form action={action}
            className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-xl border border-line bg-surface p-4 shadow-lg">
        {/* Computed values the server reads. instructor_id is empty for
            Unassigned (an open shift), which both paths treat as a null. */}
        <input type="hidden" name="instructor_id" value={instructorId} />
        {repeats && <input type="hidden" name="repeats" value="on" />}
        {repeats ? (
          <>
            <input type="hidden" name="rrule" value={rrule} />
            <input type="hidden" name="starts_on" value={dateKey} />
            <input type="hidden" name="time_of_day" value={time} />
            <input type="hidden" name="duration_minutes" value={duration} />
            <input type="hidden" name="ends_on" value={until} />
          </>
        ) : (
          <>
            <input type="hidden" name="starts_at" value={instants?.start ?? ""} />
            <input type="hidden" name="ends_at" value={instants?.end ?? ""} />
          </>
        )}

        <p className="text-[15px] font-medium leading-5 text-ink">
          {repeats ? "New repeating class" : "New class"}
        </p>
        <p className="mt-0.5 text-[12.5px] leading-[18px] text-ink-3">
          <span className="num">{duration}</span> minutes ·{" "}
          {instructorName
            ? <>with <span className="text-ink-2">{instructorName}</span></>
            : instructor === "unassigned"
              ? <>nobody assigned — an open shift instructors can apply for</>
              : <>choose who teaches it</>}.
        </p>

        {state && !state.ok && (
          <div className="mt-3 rounded border px-3 py-2 text-[13px] leading-[19px] text-ink"
               style={{ borderColor: "var(--coral)", background: "var(--coral-tint)" }} role="alert">
            {state.message}
            {blocked?.name && (
              <>
                {" "}
                <a href={blocked.occurrenceId ? `/roster/${blocked.occurrenceId}` : "#"}
                   className="font-medium underline underline-offset-4">
                  {blocked.who ? `${blocked.who} is teaching ` : ""}{blocked.name}
                  {blocked.at ? ` at ${blocked.at}` : ""}
                  {blocked.room ? ` in ${blocked.room}` : ""}
                </a>.
              </>
            )}
          </div>
        )}
        {state && state.ok && (
          <div className="mt-3 rounded border px-3 py-2 text-[13px] leading-[19px] text-ink"
               style={{ borderColor: "var(--line-2)", background: "var(--paper)" }} role="status">
            {state.message}
            {seriesOk && "seriesId" in state && (
              <>
                {" "}
                <a href={`/series/${state.seriesId}`}
                   className="font-medium underline underline-offset-4">View series</a>.
              </>
            )}
          </div>
        )}

        <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">What kind of class</span>
          <select name="class_type_id" required value={classTypeId}
                  onChange={(e) => setClassTypeId(e.target.value)} className={fieldCls}>
            <option value="">Choose…</option>
            {classTypes.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name} — {c.duration_minutes} min, holds {c.default_capacity}
              </option>
            ))}
          </select>
        </label>

        <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">
            Who teaches it
            {draft.view !== "day" && <span className="text-ink-3"> — no column on {draft.view}, so choose</span>}
          </span>
          <select required value={instructor}
                  onChange={(e) => setInstructor(e.target.value)} className={fieldCls}>
            <option value="">Choose…</option>
            <option value="unassigned">Unassigned — an open shift</option>
            {instructors.map((i) => (
              <option key={i.id} value={i.id}>{i.name}</option>
            ))}
          </select>
        </label>

        <div className="mt-3 grid grid-cols-2 gap-3">
          <label className="block text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">Date</span>
            <input type="date" required value={dateKey}
                   onChange={(e) => setDateKey(e.target.value)} className={fieldCls} />
          </label>
          <label className="block text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">Start time</span>
            <input type="time" required value={time}
                   onChange={(e) => setTime(e.target.value)} className={fieldCls} />
          </label>
        </div>

        {askRoom && (
          <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">Which room</span>
            <select name="room_id" required className={fieldCls}>
              <option value="">Choose…</option>
              {roomOptions.map((r) => (
                <option key={r.id} value={r.id}>{r.name} — holds {r.capacity}</option>
              ))}
            </select>
          </label>
        )}
        {rooms.length === 1 && <input type="hidden" name="room_id" value={rooms[0].id} />}

        <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">
            Capacity <span className="text-ink-3">— leave blank for the class type&rsquo;s own</span>
          </span>
          <input name="capacity" type="number" min={1} max={200}
                 className="w-28 rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
        </label>

        <div className="mt-4">
          <TierField coreEnabled={coreEnabled} flexEnabled={flexEnabled} />
        </div>

        {/* Decision 38 amendment: paper-first studios agree the month off-app, so
            "already confirmed" is the default when confirmations are on and a real
            instructor is chosen. Ticked → stamped confirmed-by-studio, no ask. */}
        {assignmentConfirmations && instructorId !== "" && (
          <label className="mt-4 flex items-start gap-2.5">
            <input type="checkbox" name="already_confirmed" defaultChecked className="mt-1" />
            <span className="text-[13px] leading-[19px] text-ink">
              <span className="font-medium">Already confirmed with {instructorName} — don&rsquo;t ask them</span>
              <span className="block text-[12px] leading-[18px] text-ink-3">
                Marks {repeats ? "these classes" : "this class"} confirmed by the studio, so {instructorName} is not
                asked again. Untick to have them confirm in the app.
              </span>
            </span>
          </label>
        )}

        {/* Repeats weekly — OFF by default. A calendar that silently made a year
            of classes would be a bad surprise (089); this makes the repeat, its
            days and its end date all visible before anything is created. */}
        <fieldset className="mt-4 border-t border-line pt-4">
          <label className="flex items-start gap-2.5">
            <input type="checkbox" checked={repeats}
                   onChange={(e) => setRepeats(e.target.checked)} className="mt-1" />
            <span className="text-[13px] leading-[19px] text-ink">
              <span className="font-medium">Repeats weekly</span>
              <span className="block text-[12px] leading-[18px] text-ink-3">
                Off makes one class. On makes a weekly series — pick the days and when it ends.
              </span>
            </span>
          </label>

          {repeats && (
            <div className="mt-3 space-y-3">
              <div>
                <span className="mb-1 block text-[13px] leading-[19px] text-ink-2">On which days</span>
                <div className="flex flex-wrap gap-1.5">
                  {DAY_ORDER.map((d) => {
                    const on = byday.has(d);
                    return (
                      <button key={d} type="button"
                              onClick={() => setByday((prev) => {
                                const next = new Set(prev);
                                if (next.has(d)) next.delete(d); else next.add(d);
                                return next;
                              })}
                              className="m-tap rounded-lg border px-3 py-1.5 text-[13px] font-medium"
                              style={on
                                ? { borderColor: "var(--ink)", color: "var(--ink)" }
                                : { borderColor: "var(--line-2)", color: "var(--ink-2)" }}>
                        {SHORT_DAYS[d]}
                      </button>
                    );
                  })}
                </div>
              </div>
              <label className="block text-[13px] leading-[20px] text-ink-2">
                <span className="mb-1 block">Until</span>
                <input type="date" required={repeats} value={until} min={dateKey}
                       onChange={(e) => setUntil(e.target.value)}
                       className="w-full rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
              </label>
              <p className="rounded border border-line bg-paper px-3 py-2 text-[13px] leading-[19px] text-ink"
                 role="status">
                {summary ?? "Pick the days and an end date to see what this makes."}
              </p>
            </div>
          )}
        </fieldset>

        <div className="mt-4 flex items-center gap-3">
          <Add repeats={repeats} />
          <button type="button" onClick={seriesOk ? onDone : onCancel}
                  className="m-tap rounded-lg border px-3 py-1.5 text-[13px] font-medium"
                  style={{ borderColor: "var(--line-2)", color: "var(--ink-2)" }}>
            {seriesOk ? "Done" : "Cancel"}
          </button>
        </div>
      </form>
    </div>
  );
}
