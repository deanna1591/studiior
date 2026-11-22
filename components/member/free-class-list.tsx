"use client";

import Link from "next/link";
import ClassCard from "@/components/member/class-card";
import { accentSolid } from "@/lib/accent-pair";
import { useMemo, useState, useTransition } from "react";
import { fmtTime, zonedDateKey } from "@/lib/time";
import { FREE_PICKER_HEADING, FREE_PICKER_BUTTON, freePickerSubline, freePickerTier } from "@/lib/free-picker";
import type { BookResult } from "@/app/member/actions";
import type { TimeFormat } from "@/lib/time";

type FreeClass = {
  occurrence_id: string; name: string; starts_at: string; duration_min?: number | null; room_name: string | null;
  instructor_first: string | null; instructor_avatar: string | null;
  headcount: number; capacity: number; free_bookable: boolean;
  /** Decision 22(f): the flex state, for the chip beside the time. */
  occ_flex?: boolean; occ_paid_count?: number | null; occ_min?: number | null;
  occ_reached_minimum?: boolean | null; occ_committed?: boolean | null;
};

/**
 * Decision 55 — the free booker's day strip (replacing the Decision 30 amendment
 * flat list). Only eligible classes come in; they are grouped by studio-local
 * day. The strip marks (a dot) every day with one and opens on the first such
 * day; a day with none shows the "try another day" line. Each row is the member
 * class card (Decision 30 f) with its tier chip and one "Book for free" button;
 * a cap-full class is muted and unbookable. The member picks their one free
 * class; once booked they are no longer eligible and the picker disappears.
 */
export default function FreeClassList({
  classes, timeZone, timeFormat = "24h", bookFirstFree,
  heading, fullTimetableHref, initialDayKey, reservationFeeLabel = null,
  coreOnly = false, guaranteesEnabled = false,
}: {
  classes: FreeClass[]; timeZone: string; timeFormat?: TimeFormat;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
  // Decision 55 follow-up: the Book tab uses this as its primary view with a
  // first-timer heading, a link to the full timetable, chips to narrow by class,
  // and a ?d= deep-link day.
  heading?: string; fullTimetableHref?: string; initialDayKey?: string | null;
  // Decision 103: when the studio charges a reservation fee, the button reads
  // "Book free, {fee} to reserve" and routes to the reservation checkout instead
  // of booking directly.
  reservationFeeLabel?: string | null;
  // Decision 30 amendment: the studio limits the free first class to core
  // classes, so the line reads "These classes always run."
  coreOnly?: boolean;
  // Decision 30 (f): a core row reads "Always runs" only when the studio runs
  // guarantees, the same rule as the Book timetable.
  guaranteesEnabled?: boolean;
}) {
  const [pending, start] = useTransition();
  const [booked, setBooked] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Group by studio-local day; build the continuous day span first→last eligible.
  const { days, byDay, firstKey } = useMemo(() => {
    const byDay = new Map<string, FreeClass[]>();
    for (const c of classes) {
      const k = zonedDateKey(c.starts_at, timeZone);
      (byDay.get(k) ?? byDay.set(k, []).get(k)!).push(c);
    }
    const withClasses = [...byDay.keys()].sort();
    const days: { key: string; label: string; dow: string; hasClasses: boolean }[] = [];
    if (withClasses.length) {
      const first = new Date(`${withClasses[0]}T00:00:00Z`);
      const last = new Date(`${withClasses[withClasses.length - 1]}T00:00:00Z`);
      for (let d = new Date(first); d <= last; d = new Date(d.getTime() + 86_400_000)) {
        const key = d.toISOString().slice(0, 10);
        days.push({
          key,
          label: String(d.getUTCDate()),
          dow: new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", weekday: "short" }).format(d),
          hasClasses: byDay.has(key),
        });
      }
    }
    return { days, byDay, firstKey: withClasses[0] ?? null };
  }, [classes, timeZone]);

  const [selected, setSelected] = useState<string | null>(initialDayKey ?? firstKey);
  // Class-type chips, from the distinct class names in the eligible list. Only
  // shown when there is more than one to choose between.
  const typeNames = useMemo(
    () => [...new Set(classes.map((c) => c.name))].sort(),
    [classes],
  );
  const [typeFilter, setTypeFilter] = useState<string | null>(null);
  if (classes.length === 0 || !firstKey) return null;
  const key = selected ?? firstKey;
  const rows = (byDay.get(key) ?? [])
    .filter((c) => !typeFilter || c.name === typeFilter)
    .slice().sort((a, b) => a.starts_at.localeCompare(b.starts_at));

  const book = (id: string) => start(async () => {
    const f = new FormData();
    f.set("occurrence_id", id);
    const r = await bookFirstFree({ ok: false, message: "" }, f);
    if (r && r.ok) { setBooked(id); setErr(null); } else setErr(r?.message ?? "That didn't work. Please try again.");
  });

  return (
    <section aria-label="Your free class" className="mb-5">
      <h2 className="m-head mb-1 text-[16px] leading-5 text-ink">{heading ?? FREE_PICKER_HEADING}</h2>
      <p className="m-sub mb-3 text-[12.5px] leading-[18px] text-ink-2">
        {freePickerSubline({ coreOnly, reservationFeeLabel })}
        {fullTimetableHref && (
          <> · <Link href={fullTimetableHref} className="text-lime-text underline underline-offset-4">See all classes</Link></>
        )}
      </p>

      {/* Class-type chips — narrow the eligible classes. Only when there's a choice. */}
      {typeNames.length > 1 && (
        <div className="mb-3 flex flex-wrap gap-1.5">
          <button type="button" onClick={() => setTypeFilter(null)}
                  className="m-press rounded-full px-3 py-1 text-[12px] font-semibold"
                  style={typeFilter === null
                    ? accentSolid()
                    : { background: "var(--surface)", color: "var(--ink-2)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
            All
          </button>
          {typeNames.map((n) => (
            <button key={n} type="button" onClick={() => setTypeFilter(n)}
                    className="m-press rounded-full px-3 py-1 text-[12px] font-semibold"
                    style={typeFilter === n
                      ? accentSolid()
                      : { background: "var(--surface)", color: "var(--ink-2)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              {n}
            </button>
          ))}
        </div>
      )}

      {/* Day strip: a dot marks a day with at least one eligible class. */}
      <div className="mb-3 flex gap-1.5 overflow-x-auto pb-1" role="tablist" aria-label="Pick a day">
        {days.map((d) => {
          const on = d.key === key;
          return (
            <button key={d.key} role="tab" aria-selected={on} onClick={() => setSelected(d.key)}
                    className="m-press flex min-w-[46px] flex-col items-center rounded-2xl px-1 py-1.5"
                    style={on
                      ? accentSolid()
                      : { background: "var(--surface)", color: "var(--ink-2)",
                          boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
              <span className="text-[10px] uppercase tracking-wide">{d.dow}</span>
              <span className="num text-[15px] font-semibold leading-5">{d.label}</span>
              <span className="mt-0.5 h-1 w-1 rounded-full"
                    style={{ background: d.hasClasses
                      ? (on ? "var(--accent-on-solid)" : "var(--lime-text)") : "transparent" }} />
            </button>
          );
        })}
      </div>

      {err && (
        <p className="mb-2 rounded-lg px-3 py-2 text-[12.5px] leading-[18px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}

      {rows.length === 0 ? (
        <p className="rounded-2xl bg-surface px-3.5 py-6 text-center text-[13px] leading-[19px] text-ink-2"
           style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
          No free-class slots this day. Try another day.
        </p>
      ) : (
        // Decision 30 (f): every row is the member class card Book uses, with
        // its tier chip, and one round "Book for free" button. A fee routes the
        // tap to the reservation step; the class page keeps the credit box.
        <ul className="space-y-3">
          {rows.map((c) => {
            const isBooked = booked === c.occurrence_id;
            const tier = freePickerTier(c, { guaranteesEnabled });
            const mins = Number(c.duration_min) || 0;
            const end = mins ? new Date(new Date(c.starts_at).getTime() + mins * 60_000).toISOString() : null;
            const left = Math.max(0, (c.capacity ?? 0) - (c.headcount ?? 0));
            const btnStyle = tier.alwaysRuns
              ? { background: "transparent", color: "var(--ink)", boxShadow: "inset 0 0 0 1.5px var(--ink)" }
              : { background: "var(--accent-chip)", color: "var(--ink)" };
            const btnClass = "m-tap m-press flex w-full items-center justify-center rounded-full px-4 text-center text-[13px] font-bold disabled:opacity-60";
            const action = isBooked || !c.free_bookable ? null
              : reservationFeeLabel ? (
                <Link href={`/reserve/${c.occurrence_id}`} className={btnClass} style={btnStyle}>
                  {FREE_PICKER_BUTTON}
                </Link>
              ) : (
                <button type="button" onClick={() => book(c.occurrence_id)} disabled={pending}
                        className={btnClass} style={btnStyle}>
                  {pending ? "…" : FREE_PICKER_BUTTON}
                </button>
              );
            return (
              <ClassCard
                key={c.occurrence_id}
                href={`/class/${c.occurrence_id}`}
                startLabel={fmtTime(c.starts_at, timeZone, timeFormat)}
                endLabel={end ? fmtTime(end, timeZone, timeFormat) : null}
                durationLabel={mins ? `${mins} min` : ""}
                name={c.name}
                instructor={c.instructor_first}
                coachAvatar={c.instructor_avatar}
                room={c.room_name}
                statusLabel={isBooked
                  // Decision 21 amendment: a free seat confirms once the class is on.
                  ? <>Booked · we&rsquo;ll confirm once the class is on</>
                  : !c.free_bookable ? "Full for free classes"
                  : <><span className="num">{left}</span> left</>}
                statusTone={isBooked ? "booked" : !c.free_bookable ? "full" : "quiet"}
                action={action}
                stackAction
                booked={isBooked}
                alwaysRuns={tier.alwaysRuns}
                flexState={tier.flexState}
              />
            );
          })}
        </ul>
      )}
    </section>
  );
}
