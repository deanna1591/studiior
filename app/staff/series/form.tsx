"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, buttonQuietClass, inputClass } from "@/components/ui";
import { DAYS, type DayCode, type Rule, buildRrule, describeRule } from "@/lib/rrule";
import {
  createSeries, previewSeries, applySeries,
  type SeriesState, type EditState,
} from "./actions";

export type SeriesDraft = {
  id?: string;
  name: string;
  class_type_id: string | null;
  room_id: string | null;
  instructor_id: string | null;
  capacity: number;
  duration_minutes: number;
  starts_on: string;
  ends_on: string | null;
  time_of_day: string;
  description: string | null;
  rule: Rule;
  unsupported: string | null;
};

type Option = { id: string; name: string; capacity?: number; duration?: number };

function Submit({ label, busy, quiet }: { label: string; busy: string; quiet?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button className={quiet ? buttonQuietClass : buttonClass} disabled={pending}>
      {pending ? busy : label}
    </button>
  );
}

/**
 * Seven toggles, because a text field is how a rule the parser refuses gets typed.
 *
 * The setter takes the updater form deliberately. Computing the next array from
 * the `days` prop looks identical and is wrong: two clicks inside one render
 * both read the same captured value and the second silently discards the first.
 * Rare with a mouse, ordinary with a keyboard or a script.
 */
function DayPicker({ days, onChange }: {
  days: DayCode[]; onChange: React.Dispatch<React.SetStateAction<DayCode[]>>;
}) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {DAYS.map((d) => {
        const on = days.includes(d.code);
        return (
          <button
            key={d.code}
            type="button"
            aria-pressed={on}
            onClick={() =>
              onChange((prev) =>
                prev.includes(d.code) ? prev.filter((x) => x !== d.code) : [...prev, d.code])
            }
            className={`h-9 min-w-[46px] rounded px-2 text-[13px] leading-[18px] ${
              on ? "bg-ink text-paper" : "border border-line-2 bg-surface text-ink-2 hover:bg-paper"
            }`}
          >
            {d.short}
          </button>
        );
      })}
    </div>
  );
}

export default function SeriesForm({
  draft, mode, classTypes, rooms, instructors, timeZone, tomorrow,
}: {
  draft: SeriesDraft;
  mode: "create" | "edit";
  classTypes: Option[];
  rooms: Option[];
  instructors: Option[];
  timeZone: string;
  /** Formatted on the server: a Date crossing the boundary is a runtime error. */
  tomorrow: string;
}) {
  const [name, setName] = useState(draft.name);
  const [classTypeId, setClassTypeId] = useState(draft.class_type_id ?? "");
  const [roomId, setRoomId] = useState(draft.room_id ?? "");
  const [instructorId, setInstructorId] = useState(draft.instructor_id ?? "");
  const [capacity, setCapacity] = useState(draft.capacity);
  const [duration, setDuration] = useState(draft.duration_minutes);
  const [startsOn, setStartsOn] = useState(draft.starts_on);
  const [time, setTime] = useState(draft.time_of_day.slice(0, 5));
  const [description, setDescription] = useState(draft.description ?? "");
  const [days, setDays] = useState<DayCode[]>(draft.rule.days);
  const [interval, setInterval] = useState(draft.rule.interval);
  const [ends, setEnds] = useState<"never" | "on" | "after">(
    draft.rule.count ? "after" : draft.ends_on ? "on" : "never",
  );
  const [endsOn, setEndsOn] = useState(draft.ends_on ?? "");
  const [count, setCount] = useState(draft.rule.count ?? 8);
  const [effectiveFrom, setEffectiveFrom] = useState(tomorrow);

  const rule: Rule = { days, interval, count: ends === "after" ? count : null };
  const rrule = useMemo(() => buildRrule(rule), [days, interval, ends, count]);
  const endsOnValue = ends === "on" ? endsOn : "";
  const sentence = describeRule(rule, endsOnValue || null, time);

  const [createState, createAction] = useFormState<SeriesState, FormData>(createSeries, null);
  const [editState, previewAction] = useFormState<EditState, FormData>(previewSeries, null);
  const [applyState, applyAction] = useFormState<EditState, FormData>(applySeries, null);

  const shown = applyState ?? editState;

  const hidden = (
    <>
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <input type="hidden" name="rrule" value={rrule} />
      <input type="hidden" name="name" value={name} />
      <input type="hidden" name="class_type_id" value={classTypeId} />
      <input type="hidden" name="room_id" value={roomId} />
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="capacity" value={capacity} />
      <input type="hidden" name="duration_minutes" value={duration} />
      <input type="hidden" name="starts_on" value={startsOn} />
      <input type="hidden" name="ends_on" value={endsOnValue} />
      <input type="hidden" name="time_of_day" value={time} />
      <input type="hidden" name="description" value={description} />
      <input type="hidden" name="effective_from" value={effectiveFrom} />
    </>
  );

  return (
    <div className="max-w-xl">
      {draft.unsupported && (
        <Notice kind="error">
          This series repeats in a way Studiior cannot keep ({draft.unsupported}), so the
          controls below start empty. Saving replaces the rule with the one you build here.
        </Notice>
      )}

      <form action={mode === "create" ? createAction : previewAction} className="space-y-4">
        {createState && <Notice kind="error">{createState.error}</Notice>}
        {shown && "error" in shown && <Notice kind="error">{shown.error}</Notice>}
        {hidden}

        <Field label="Name">
          <input required value={name} onChange={(e) => setName(e.target.value)}
                 className={inputClass} placeholder="Reformer Flow" />
        </Field>

        <Field label="Class type">
          <select value={classTypeId} className={inputClass}
                  onChange={(e) => {
                    setClassTypeId(e.target.value);
                    const ct = classTypes.find((c) => c.id === e.target.value);
                    if (ct?.duration) setDuration(ct.duration);
                    if (ct?.capacity) setCapacity(ct.capacity);
                    if (ct && !name) setName(ct.name);
                  }}>
            <option value="">No class type</option>
            {classTypes.map((c) => (
              <option key={c.id} value={c.id}>{c.name} ({c.duration} min)</option>
            ))}
          </select>
        </Field>

        <Field label="Room">
          <select value={roomId} className={inputClass}
                  onChange={(e) => {
                    setRoomId(e.target.value);
                    const r = rooms.find((x) => x.id === e.target.value);
                    if (r?.capacity) setCapacity(r.capacity);
                  }}>
            <option value="">No room</option>
            {rooms.map((r) => (
              <option key={r.id} value={r.id}>{r.name} (holds {r.capacity})</option>
            ))}
          </select>
        </Field>

        {/* Decision 17, and the reason the fill engine has anything to do. Blank
            is the normal case and the copy has to say so, or it reads as a
            field somebody forgot to complete. */}
        <Field label="Instructor">
          <select value={instructorId} onChange={(e) => setInstructorId(e.target.value)}
                  className={inputClass}>
            <option value="">Leave open — assign later</option>
            {instructors.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
          </select>
          <p className="mt-1 text-xs text-ink-3">
            Leaving this open is the usual way round. Every class the series makes
            becomes an open shift, which instructors can apply for and which
            “Fill a month” can assign from qualifications and availability.
            Naming somebody here puts them on all of them.
          </p>
        </Field>

        <div className="grid grid-cols-2 gap-3">
          <Field label="Start time">
            <input type="time" required value={time} onChange={(e) => setTime(e.target.value)}
                   className={inputClass} />
          </Field>
          <Field label="Length (minutes)">
            <input type="number" min={1} required value={duration}
                   onChange={(e) => setDuration(Number(e.target.value))} className={inputClass} />
          </Field>
        </div>

        <Field label="Capacity">
          <input type="number" min={1} required value={capacity}
                 onChange={(e) => setCapacity(Number(e.target.value))} className={inputClass} />
        </Field>

        <Field label="Repeats on">
          <DayPicker days={days} onChange={setDays} />
        </Field>

        <Field label="How often">
          <select value={interval} onChange={(e) => setInterval(Number(e.target.value))}
                  className={inputClass}>
            <option value={1}>Every week</option>
            <option value={2}>Every other week</option>
            <option value={3}>Every third week</option>
            <option value={4}>Every fourth week</option>
          </select>
        </Field>

        <div className="grid grid-cols-2 gap-3">
          <Field label="First class on">
            <input type="date" required value={startsOn}
                   onChange={(e) => setStartsOn(e.target.value)} className={inputClass} />
          </Field>
          <Field label="Ends">
            <select value={ends} className={inputClass}
                    onChange={(e) => setEnds(e.target.value as typeof ends)}>
              <option value="never">Keeps going</option>
              <option value="on">On a date</option>
              <option value="after">After a number of classes</option>
            </select>
          </Field>
        </div>

        {ends === "on" && (
          <Field label="Last class on or before">
            <input type="date" value={endsOn} onChange={(e) => setEndsOn(e.target.value)}
                   className={inputClass} />
          </Field>
        )}
        {ends === "after" && (
          <Field label="Number of classes">
            <input type="number" min={1} value={count}
                   onChange={(e) => setCount(Number(e.target.value))} className={inputClass} />
          </Field>
        )}

        <Field label="Description">
          <textarea value={description} onChange={(e) => setDescription(e.target.value)}
                    rows={3} className={inputClass}
                    placeholder="What members see on the class. Leave blank to use the class type's." />
        </Field>

        {/* The rule as a sentence. Nobody should have to read RFC 5545 to check
            their own timetable, and the raw string is below it for anyone who
            wants to. */}
        <div className="rounded border border-line bg-paper px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">{sentence}</p>
          <p className="num mt-1 text-[11px] leading-4 text-ink-3">{rrule || "—"}</p>
          <p className="mt-1 text-[12px] leading-4 text-ink-3">
            Times are {timeZone.replace("_", " ")}, and stay that way across the clock
            change — a 07:00 class is 07:00 in March and in November.
          </p>
        </div>

        {mode === "edit" && (
          <Field label="Changes apply from"
                 hint="Classes before this date keep the time they were taught at. A class somebody has already moved on the calendar is left where it was put.">
            <input type="date" value={effectiveFrom}
                   onChange={(e) => setEffectiveFrom(e.target.value)} className={inputClass} />
          </Field>
        )}

        <div className="flex items-center gap-4">
          <Submit
            label={mode === "create" ? "Create series" : "Preview changes"}
            busy={mode === "create" ? "Creating…" : "Working it out…"}
          />
          <Link href="/series" className="text-sm text-ink-2 underline underline-offset-4">
            Cancel
          </Link>
        </div>
      </form>

      {mode === "edit" && shown && "result" in shown && (
        <Outcome result={shown.result} applied={applyState !== null}>
          <form action={applyAction}>{hidden}<Submit label="Apply these changes" busy="Applying…" /></form>
        </Outcome>
      )}
    </div>
  );
}

/**
 * What the edit will do, in the database's own numbers.
 *
 * Every line here is a count update_series() returned. The screen does no
 * arithmetic of its own: a preview that guesses is a preview that can disagree
 * with the apply.
 */
function Outcome({
  result, applied, children,
}: {
  result: Extract<EditState, { result: unknown }>["result"];
  applied: boolean;
  children: React.ReactNode;
}) {
  if (!result.ok && "reason" in result && result.reason === "members_booked_on_dropped_classes") {
    return (
      <section className="mt-6 rounded border border-coral bg-coral-tint px-3.5 py-3">
        <p className="text-[13px] leading-[19px] text-ink">
          This change would stop {result.blocked.length}{" "}
          {result.blocked.length === 1 ? "class that has" : "classes that have"} people booked
          on {result.blocked.length === 1 ? "it" : "them"}. Nothing has been changed. Cancel
          {result.blocked.length === 1 ? " that class" : " those classes"} on the calendar
          first, so the members are told, then come back.
        </p>
        <ul className="mt-2 space-y-1">
          {result.blocked.map((b) => (
            <li key={b.occurrence_id} className="text-[13px] leading-[19px] text-ink-2">
              {b.local} — <span className="num">{b.booked}</span> booked
            </li>
          ))}
        </ul>
      </section>
    );
  }

  if (!result.ok && "reason" in result && result.reason === "capacity_below_booked") {
    return (
      <section className="mt-6 rounded border border-coral bg-coral-tint px-3.5 py-3">
        <p className="text-[13px] leading-[19px] text-ink">
          Capacity of <span className="num">{result.capacity}</span> is below what is already
          booked on {result.over_capacity.length}{" "}
          {result.over_capacity.length === 1 ? "class" : "classes"}. Nothing has been changed —
          Studiior never picks who loses their spot.
        </p>
        <ul className="mt-2 space-y-1">
          {result.over_capacity.map((b) => (
            <li key={b.occurrence_id} className="text-[13px] leading-[19px] text-ink-2">
              {b.local} — <span className="num">{b.booked}</span> booked
            </li>
          ))}
        </ul>
      </section>
    );
  }

  const lines: string[] = [];
  if (result.ok) {
    if (result.moved) lines.push(`${result.moved} classes moved`);
    if (result.added) lines.push(`${result.added} classes added`);
    if (result.restored) lines.push(`${result.restored} cancelled classes put back on`);
    if (result.cancelled) lines.push(`${result.cancelled} classes cancelled`);
    if (result.members_emailed) lines.push(`${result.members_emailed} members emailed`);
    if (result.left_as_edited) lines.push(`${result.left_as_edited} left as you had already edited them`);
  } else if ("will_move" in result) {
    if (result.will_move) lines.push(`${result.will_move} classes will move`);
    if (result.will_add) lines.push(`${result.will_add} classes will be added`);
    if (result.will_restore) lines.push(`${result.will_restore} cancelled classes will go back on`);
    if (result.will_cancel) lines.push(`${result.will_cancel} classes will be cancelled`);
    if (result.members_emailed) lines.push(`${result.members_emailed} members will be emailed`);
    if (result.unchanged) lines.push(`${result.unchanged} are already right`);
    if (result.left_as_edited) lines.push(`${result.left_as_edited} you have already edited will be left alone`);
  }

  return (
    <section className="mt-6 rounded border border-line bg-surface px-3.5 py-3">
      <p className="section-label text-ink-2">{applied ? "What happened" : "What this will do"}</p>
      <p className="mt-1.5 text-[13px] leading-[19px] text-ink">
        From {result.effective_from}.{" "}
        {lines.length === 0 ? "Nothing on the calendar changes." : `${lines.join(", ")}.`}
      </p>
      {/* THE POST-CONDITION, and it outranks every count above it. Those describe
          what each step believed it was doing; this is what the calendar says
          afterwards. A studio that edits a series and sees it unchanged has no
          other way to tell that from success. */}
      {result.ok && result.still_out_of_step > 0 && (
        <section className="mt-4 rounded border border-coral bg-coral-tint px-3.5 py-3">
          <p className="text-[13px] leading-[19px] text-ink">
            <strong>The calendar does not match this series.</strong>{" "}
            <span className="num">{result.still_out_of_step}</span>{" "}
            {result.still_out_of_step === 1 ? "class is" : "classes are"} still at the old
            time or day{applied ? "" : " and would stay there"}.
            {result.predicted.moved > result.moved && (
              <>
                {" "}This edit expected to move{" "}
                <span className="num">{result.predicted.moved}</span> and moved{" "}
                <span className="num">{result.moved}</span>.
              </>
            )}{" "}
            Nothing below overrides this line.
          </p>
        </section>
      )}

      {result.ok && result.conflicts.length > 0 && (
        <>
          <p className="mt-3 text-[13px] leading-[19px] text-ink">
            {result.conflicts.length} could not be moved, because the room or the instructor
            is already busy then. The rest went through.
          </p>
          <ul className="mt-1.5 space-y-1">
            {result.conflicts.map((c) => (
              <li key={c.occurrence_id} className="text-[13px] leading-[19px] text-ink-2">
                {c.local} — {c.reason === "room_busy" ? "room already in use" : "instructor already teaching"}
              </li>
            ))}
          </ul>
        </>
      )}
      {!applied && <div className="mt-3">{children}</div>}
    </section>
  );
}
