"use client";

import { useState, useCallback, type ReactNode } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Icon } from "@/components/member/icons";
import { MonthGrid, type MonthDay } from "@/components/member/week-strip";
import DateStrip, { type StripDay } from "@/components/member/date-strip";
import DayView from "@/components/member/day-view";
import DayClasses, { type Row } from "@/components/member/day-classes";
import type { BookResult, ActionResult, CheckInResult } from "@/app/member/actions";

/**
 * The Book tab, a day at a time — but the WEEK is fetched once (1 Nov speed
 * pass). The server computes every per-day bundle (rows, the peak line, the
 * closed/draft/next-class empty states) for the visible window and hands them
 * over; this component only SELECTS which day to show, filters it by class type
 * and instructor, and keeps the URL in sync with history.replaceState. No
 * refetch happens until the window itself changes (a day outside the fetched
 * week, month paging, or the Week/Month toggle), which stays a navigation.
 *
 * The booking RULES never moved: `rows` arrive fully resolved (peak-blocked,
 * holding a seat, the free-cancellation note, …), exactly as the server-rendered
 * page produced them, so the client cannot get booking behaviour wrong — the
 * worst it can do is show the wrong day. First paint is the server-rendered
 * selected day, so the page is never blank.
 */

export type PeakLine = { remaining: number | null; allowance: number; resetsOn: string | null };
export type ClosedInfo = { timeRange: string | null; reason: string; untilText: string | null };
export type NextClass = { dateText: string; count: number; offset: number };

export type DayBundle = {
  offset: number;
  rows: Row[];
  /** Decision 24: the peak-allowance line for this day's period, or null. */
  peakLine: PeakLine | null;
  /** "We're closed" for this day (Decision 74), or null. */
  closed: ClosedInfo | null;
  /** Decision 25: a draft (unpublished) month — the month label to name, else null. */
  draftMonthLabel: string | null;
  draftThroughText: string | null;
  /** Decision 30: for a genuinely empty day, where the timetable next has a class. */
  nextClass: NextClass | null;
};

type FilterOpt = { id: string; label: string };

export default function BookWeek({
  bundles,
  initialOffset,
  stripDays,
  monthDays,
  monthView,
  monthLabel,
  showAll,
  horizon,
  types,
  instructors,
  initialType,
  initialInstructor,
  bookClass,
  bookFirstFree,
  freeFirstEligible,
  freeEligibleIds,
  selfCheckIn,
  startCheckout,
  payAtDesk,
  opensBeforeMin,
  closesAfterMin,
}: {
  bundles: DayBundle[];
  initialOffset: number;
  /** The 84-day strip (hrefs precomputed on the server for out-of-window days). */
  stripDays: StripDay[];
  monthDays: MonthDay[];
  monthView: boolean;
  monthLabel: string;
  /** The "Back to your free class" state keeps ?all=1 on every link. */
  showAll: boolean;
  horizon: ReactNode;
  types: FilterOpt[];
  instructors: FilterOpt[];
  initialType: string;
  initialInstructor: string;
  bookClass: (p: BookResult, f: FormData) => Promise<BookResult>;
  bookFirstFree: (p: BookResult, f: FormData) => Promise<BookResult>;
  freeFirstEligible: boolean;
  freeEligibleIds: string[];
  selfCheckIn: (bookingId: string, lat: number | null, lng: number | null, accuracy: number | null) => Promise<CheckInResult>;
  startCheckout: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  payAtDesk: (p: ActionResult, f: FormData) => Promise<ActionResult>;
  opensBeforeMin: number;
  closesAfterMin: number;
}) {
  const router = useRouter();
  const [sel, setSel] = useState(initialOffset);
  const [typeFilter, setTypeFilter] = useState(initialType);
  const [instFilter, setInstFilter] = useState(initialInstructor);
  const freeSet = new Set(freeEligibleIds);
  const windowOffsets = new Set(bundles.map((b) => b.offset));

  // The canonical /book URL, mirroring the server's qs(). Pure, so it can run
  // client-side for replaceState and for out-of-window navigation.
  const hrefFor = useCallback((o: { d?: number; type?: string; instructor?: string; v?: string }) => {
    const p = new URLSearchParams();
    const merged: Record<string, string | number | undefined> = {
      d: o.d, v: o.v, type: o.type, instructor: o.instructor, all: showAll ? "1" : undefined,
    };
    for (const [k, v] of Object.entries(merged)) {
      if (v !== undefined && v !== "" && !(k === "d" && v === 0)) p.set(k, String(v));
    }
    const q = p.toString();
    return q ? `/book?${q}` : "/book";
  }, [showAll]);

  // Keep the URL honest without navigating, so a refresh/share lands on the same
  // day and filters and the back button still works.
  const syncUrl = useCallback((d: number, type: string, instructor: string) => {
    if (typeof window === "undefined") return;
    const url = hrefFor({ d, type: type || undefined, instructor: instructor || undefined, v: monthView ? "month" : undefined });
    window.history.replaceState(window.history.state, "", url);
  }, [hrefFor, monthView]);

  // A day inside the fetched window is instant; outside it navigates (the window
  // changes, so the server refetches).
  const pickDay = useCallback((offset: number) => {
    if (!windowOffsets.has(offset)) {
      router.push(hrefFor({ d: offset, type: typeFilter || undefined, instructor: instFilter || undefined, v: monthView ? "month" : undefined }), { scroll: false });
      return;
    }
    setSel(offset);
    syncUrl(offset, typeFilter, instFilter);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [router, hrefFor, typeFilter, instFilter, monthView, syncUrl]);

  const toggleType = (id: string) => {
    const next = typeFilter === id ? "" : id;
    setTypeFilter(next); syncUrl(sel, next, instFilter);
  };
  const toggleInst = (id: string) => {
    const next = instFilter === id ? "" : id;
    setInstFilter(next); syncUrl(sel, typeFilter, next);
  };
  const clearFilters = () => { setTypeFilter(""); setInstFilter(""); syncUrl(sel, "", ""); };

  const bundle = bundles.find((b) => b.offset === sel) ?? bundles[0];
  const rows = (bundle?.rows ?? []).filter(
    (r) => (!typeFilter || r.classTypeId === typeFilter) &&
           (!instFilter || r.instructorId === instFilter),
  );
  const filtered = !!typeFilter || !!instFilter;
  const peakLine = bundle?.peakLine ?? null;

  const Pill = ({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) => (
    <button type="button" onClick={onClick} aria-pressed={active}
      className="m-tap inline-flex shrink-0 items-center rounded-full px-3.5 text-[13px] font-semibold"
      style={active
        ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
        : { background: "var(--surface)", color: "var(--ink-2)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
      {children}
    </button>
  );

  return (
    <>
      <section aria-label="Choose a day" className="mb-4">
        <div className="mb-2.5 flex items-center gap-2">
          <h2 className="m-head flex-1 truncate text-[17px] leading-6 text-ink">{monthLabel}</h2>
          {/* Week / Month stays a navigation — it swaps the whole day navigator
              and the fetched window. Day switching and filtering below are the
              frequent taps and are now instant. */}
          <div className="flex rounded-full p-0.5" style={{ background: "var(--surface)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
            {([["week", "Week"], ["month", "Month"]] as const).map(([v, label]) => {
              const on = monthView === (v === "month");
              return (
                <Link key={v} href={hrefFor({ d: sel, type: typeFilter || undefined, instructor: instFilter || undefined, v: v === "week" ? undefined : v })}
                  aria-pressed={on}
                  className="m-press flex min-h-[44px] items-center rounded-full px-3.5 text-[12px] font-semibold leading-4"
                  style={on ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" } : { color: "var(--ink-2)" }}>
                  {label}
                </Link>
              );
            })}
          </div>
          {monthView && (
            <div className="flex items-center gap-1">
              <Link href={hrefFor({ d: sel - 28, type: typeFilter || undefined, instructor: instFilter || undefined, v: "month" })} aria-label="Earlier"
                className="m-press flex h-11 w-11 items-center justify-center rounded-full bg-surface text-ink-2" style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
                <Icon name="chevron-left" size={18} />
              </Link>
              <Link href={hrefFor({ d: sel + 28, type: typeFilter || undefined, instructor: instFilter || undefined, v: "month" })} aria-label="Later"
                className="m-press flex h-11 w-11 items-center justify-center rounded-full bg-surface text-ink-2" style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
                <Icon name="chevron-right" size={18} />
              </Link>
            </div>
          )}
        </div>

        {monthView
          ? <MonthGrid days={monthDays.map((d) => ({ ...d, isSelected: d.offset === sel }))} hrefFor={(o) => hrefFor({ d: o, v: undefined })} />
          : <DateStrip
              days={stripDays.map((d) => ({ ...d, isSelected: d.offset === sel }))}
              selectedOffset={sel}
              onSelect={pickDay}
              windowOffsets={windowOffsets} />}
      </section>

      <div className="m-hscroll -mx-4 mb-4 flex items-center gap-2 overflow-x-auto px-4 pb-1">
        <Pill active={!typeFilter && !instFilter} onClick={clearFilters}>All</Pill>
        {types.map((t) => (
          <Pill key={t.id} active={typeFilter === t.id} onClick={() => toggleType(t.id)}>{t.label}</Pill>
        ))}
        {instructors.length > 0 && (
          <span className="m-micro flex shrink-0 items-center gap-2 pl-1 text-ink-2">
            <span className="h-5 w-px bg-line-2" aria-hidden /> Taught by
          </span>
        )}
        {instructors.map((i) => (
          <Pill key={i.id} active={instFilter === i.id} onClick={() => toggleInst(i.id)}>{i.label}</Pill>
        ))}
      </div>

      {peakLine && (
        <p className={`m-meta mb-3 rounded-xl px-3 py-2 ${peakLine.remaining === 0 ? "bg-coral-tint text-ink" : "bg-accent-chip text-ink"}`}>
          {peakLine.remaining === 0 ? (
            <>You have used all <span className="num">{peakLine.allowance}</span> of your peak classes for this period. Off-peak classes are unlimited, and your peak classes come back on {peakLine.resetsOn}.</>
          ) : (
            <><span className="num">{peakLine.remaining}</span> of <span className="num">{peakLine.allowance}</span> peak classes left this period. Off-peak classes are unlimited.</>
          )}
        </p>
      )}

      {horizon}

      <DayView key={sel}
        prevHref={hrefFor({ d: sel - 1, type: typeFilter || undefined, instructor: instFilter || undefined })}
        nextHref={hrefFor({ d: sel + 1, type: typeFilter || undefined, instructor: instFilter || undefined })}
        onPrev={windowOffsets.has(sel - 1) ? () => pickDay(sel - 1) : undefined}
        onNext={windowOffsets.has(sel + 1) ? () => pickDay(sel + 1) : undefined}>
        {rows.length === 0 ? (
          <div className="m-card p-6 text-center">
            <p className="m-body text-ink">
              {bundle?.closed
                ? bundle.closed.timeRange ? `${bundle.closed.timeRange} — ${bundle.closed.reason}` : bundle.closed.reason
                : bundle?.draftMonthLabel
                ? `${bundle.draftMonthLabel}'s timetable is not published yet.`
                : filtered ? "Nothing matching on this day."
                : bundle?.nextClass ? `Classes start ${bundle.nextClass.dateText}.`
                : "No classes on this day."}
            </p>
            <p className="m-sub mt-1 text-ink-2">
              {bundle?.closed
                ? <>The studio is closed{bundle.closed.untilText && <> until {bundle.closed.untilText}</>}.{" "}
                    <button type="button" onClick={() => pickDay(sel + 1)} className="text-lime-text underline underline-offset-4">Look at another day</button></>
                : bundle?.draftMonthLabel
                ? <>It opens for booking when the studio publishes it.{bundle.draftThroughText && <> You can book through {bundle.draftThroughText}.</>}</>
                : filtered
                ? <button type="button" onClick={clearFilters} className="text-lime-text underline underline-offset-4">Show everything</button>
                : bundle?.nextClass
                ? <button type="button" onClick={() => pickDay(bundle.nextClass!.offset)} className="text-lime-text underline underline-offset-4">
                    See the {bundle.nextClass.count} {bundle.nextClass.count === 1 ? "class" : "classes"} on that day
                  </button>
                : <button type="button" onClick={() => pickDay(sel + 1)} className="text-lime-text underline underline-offset-4">Try tomorrow</button>}
            </p>
          </div>
        ) : (
          <DayClasses
            rows={rows}
            bookClass={bookClass}
            bookFirstFree={bookFirstFree}
            freeFirstEligible={freeFirstEligible}
            freeEligibleIds={freeSet}
            selfCheckIn={selfCheckIn}
            startCheckout={startCheckout}
            payAtDesk={payAtDesk}
            opensBeforeMin={opensBeforeMin}
            closesAfterMin={closesAfterMin}
          />
        )}
      </DayView>
    </>
  );
}
