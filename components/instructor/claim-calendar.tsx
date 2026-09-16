"use client";

import { useMemo, useState } from "react";
import { useFormState } from "react-dom";
import Link from "next/link";
import { claimClass, type ClaimState } from "@/app/member/instructor/actions";

// The claim screen an instructor lives in — Apple Calendar's shape in the
// studio's own accent (via lib/theme.ts, so a navy studio gets a navy screen).
// A month grid with dots under each day; tap a day to list its classes with a
// Commit beside each; a confirm sheet that tells them core-or-flex and where
// they stand. Two things are NOT the accent: the core dot / flex ring are dark
// INK (they mark what a class IS, distinct from the accent that marks what is
// already theirs), and the over-cap warning is amber (it belongs to the warning).

export type ClaimClassRow = {
  id: string; starts_at: string; date: string; time: string;
  class_name: string; duration_minutes: number; room: string | null;
  spaces_left: number; capacity: number; tier: string;
  qualified: boolean; available: boolean; valid: boolean;
  mine: boolean; clashes: boolean; week_core: number;
};
export type MonthBlock = { month: string; can_claim: boolean; reason: string | null; classes: ClaimClassRow[] };
export type Terms = {
  guarantees_enabled: boolean; flex_enabled: boolean;
  core_cutoff_hours: number | null;
  holding_kind: "flat" | "pct" | null; holding_cents: number | null; holding_pct: number | null;
  flex_deadline_mode: string | null; flex_deadline_time: string | null; flex_deadline_hours: number | null;
} | null;

const DOW = ["S", "M", "T", "W", "T", "F", "S"];
const takeable = (c: ClaimClassRow) => c.qualified && c.available && c.valid && !c.clashes && !c.mine;
// Actionable in the day list by default: something they can take, already theirs,
// or a core class blocked only by the cap (they can still ask).
const actionable = (c: ClaimClassRow, cap: number) =>
  takeable(c) || c.mine || (c.tier === "core" && c.qualified && c.available && c.valid && !c.clashes && c.week_core >= cap);

/** core = filled ink, flex/always = hollow ink ring, mine = accent (its TEXT
 *  step, safe as a small mark on a white card). */
function Mark({ tier, mine, size = 8 }: { tier: string; mine: boolean; size?: number }) {
  const s = { width: size, height: size, borderRadius: "50%", flexShrink: 0, display: "inline-block" } as const;
  if (mine) return <span style={{ ...s, background: "var(--lime-text)" }} />;
  if (tier === "core") return <span style={{ ...s, background: "var(--ink)" }} />;
  return <span style={{ ...s, boxShadow: "inset 0 0 0 1.8px var(--ink)" }} />;
}

export default function ClaimCalendar({
  months, coreCap, standingCore, standingFlex, terms, currency, today, studioName,
}: {
  months: MonthBlock[]; coreCap: number; standingCore: number; standingFlex: number;
  terms: Terms; currency: string; today: string; studioName: string;
}) {
  const [mi, setMi] = useState(0);
  const block = months[mi];
  const [showAll, setShowAll] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [sheet, setSheet] = useState<{ row: ClaimClassRow; over: boolean } | null>(null);

  const money = (cents: number) =>
    new Intl.NumberFormat(undefined, { style: "currency", currency, maximumFractionDigits: 0 }).format(cents / 100);

  const byDate = useMemo(() => {
    const m = new Map<string, ClaimClassRow[]>();
    for (const c of block?.classes ?? []) (m.get(c.date) ?? m.set(c.date, []).get(c.date)!).push(c);
    return m;
  }, [block]);

  const grid = useMemo(() => {
    if (!block) return { cells: [] as (number | null)[], y: 0, mo: 0 };
    const [y, mo] = block.month.split("-").map(Number);
    const firstDow = new Date(Date.UTC(y, mo - 1, 1)).getUTCDay();
    const days = new Date(Date.UTC(y, mo, 0)).getUTCDate();
    const cells: (number | null)[] = [];
    for (let i = 0; i < firstDow; i++) cells.push(null);
    for (let d = 1; d <= days; d++) cells.push(d);
    while (cells.length % 7 !== 0) cells.push(null);
    return { cells, y, mo };
  }, [block]);

  const dateKey = (d: number) => `${grid.y}-${String(grid.mo).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
  // Dots reflect what is actionable that day (takeable or already theirs).
  const dayDots = (d: number) => (byDate.get(dateKey(d)) ?? []).filter((c) => takeable(c) || c.mine);

  const shownSelected = useMemo(() => {
    if (selected && selected.startsWith(block?.month ?? "")) return selected;
    if (today.startsWith(block?.month ?? "") && dayDots(Number(today.slice(8))).length) return today;
    for (const c of block?.classes ?? []) if (takeable(c) || c.mine) return c.date;
    return null;
  }, [selected, block, today]); // eslint-disable-line react-hooks/exhaustive-deps

  const monthLabel = (m: string) =>
    new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" }).format(new Date(`${m}-01T12:00:00Z`));
  const year = (m: string) => m.slice(0, 4);
  const longDay = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" })
      .format(new Date(`${iso}T12:00:00Z`));
  const endTime = (start: string, mins: number) => {
    const [h, m] = start.split(":").map(Number);
    const t = h * 60 + m + mins;
    return `${String(Math.floor(t / 60) % 24).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
  };

  const dayList = shownSelected ? (byDate.get(shownSelected) ?? []) : [];
  const dayAct = dayList.filter((c) => actionable(c, coreCap));
  const dayRest = dayList.filter((c) => !actionable(c, coreCap));

  return (
    <div className="-mx-1">
      {/* Header — year, Today, big month, the one governing number. */}
      <div className="px-2">
        <div className="flex items-baseline justify-between">
          <button type="button" disabled={mi === 0}
                  onClick={() => { setMi((i) => Math.max(0, i - 1)); setSelected(null); }}
                  className="m-tap text-[14px] font-semibold disabled:opacity-40"
                  style={{ color: "var(--lime-text)" }}>‹ {block ? year(block.month) : ""}</button>
          <button type="button" disabled={mi >= months.length - 1}
                  onClick={() => { setMi((i) => Math.min(months.length - 1, i + 1)); setSelected(null); }}
                  className="m-tap text-[12px] font-semibold disabled:opacity-40"
                  style={{ color: "var(--lime-text)" }}>Next ›</button>
        </div>
        <h1 className="mt-0.5 text-[30px] font-extrabold leading-tight tracking-tight text-ink">
          {block ? monthLabel(block.month) : ""}
        </h1>
        <p className="mt-1 text-[12px] font-medium text-ink-2">
          <b style={{ color: "var(--lime-text)" }}>{standingCore} of {coreCap}</b> core this week
          {standingFlex > 0 && <> · {standingFlex} flex</>}
        </p>
      </div>

      {/* Weekday header. */}
      <div className="mt-3 grid grid-cols-7 px-2">
        {DOW.map((d, i) => (
          <div key={i} className="text-center text-[10px] font-bold tracking-wide text-ink-3">{d}</div>
        ))}
      </div>

      {/* The grid. */}
      <div className="grid grid-cols-7 border-b border-line px-1 pb-2">
        {grid.cells.map((d, i) => {
          if (d === null) return <span key={i} className="h-11" />;
          const key = dateKey(d);
          const dots = dayDots(d);
          const isToday = key === today;
          const isSel = key === shownSelected;
          return (
            <button key={i} type="button" onClick={() => setSelected(key)}
                    className="m-tap flex h-11 flex-col items-center pt-1">
              <span className="flex h-[27px] w-[27px] items-center justify-center rounded-full text-[15px] font-semibold"
                    style={isToday ? { background: "var(--ink)", color: "var(--surface)" }
                      : isSel ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                      : undefined}>
                {d}
              </span>
              <span className="mt-0.5 flex h-[5px] items-center gap-[2.5px]">
                {dots.slice(0, 3).map((c, k) => <Mark key={k} tier={c.tier} mine={c.mine} size={4.5} />)}
              </span>
            </button>
          );
        })}
      </div>

      {/* Day list. */}
      <div className="px-2 pt-3">
        {!block?.can_claim ? (
          <div className="m-card px-4 py-3.5">
            <p className="text-[15px] leading-[22px] text-ink">
              Send us your {block ? monthLabel(block.month) : "month"} availability and these open up.
            </p>
            <p className="m-sub mt-0.5 text-ink-3">
              We can only put you on classes in a month you have told us you can work.
            </p>
            <Link href="/instructor/availability"
                  className="m-tap mt-3 inline-flex items-center text-[14px] font-semibold underline underline-offset-4"
                  style={{ color: "var(--lime-text)" }}>
              Add {block ? monthLabel(block.month) : ""} availability →
            </Link>
          </div>
        ) : !shownSelected ? (
          <div className="m-card px-4 py-4">
            <p className="text-[14px] text-ink-2">Nothing to claim in {block ? monthLabel(block.month) : "this month"} yet.</p>
          </div>
        ) : (
          <>
            <div className="mb-2.5 text-[12.5px] font-bold tracking-tight text-ink-2">{longDay(shownSelected)}</div>
            {dayAct.length === 0 && dayRest.length === 0 && (
              <div className="m-card px-4 py-3.5"><p className="text-[14px] text-ink-2">Nothing to claim on this day.</p></div>
            )}
            <ul>
              {dayAct.map((c) => {
                const over = c.tier === "core" && !c.mine && c.week_core >= coreCap;
                return (
                  <li key={c.id}
                      className="mb-2 flex items-center gap-2.5 rounded-2xl bg-[color:var(--surface)] px-3 py-2.5"
                      style={c.mine ? { boxShadow: "0 0 0 1.5px var(--lime-text), var(--m-shadow-sm, 0 1px 2px rgba(0,0,0,.05))" } : { boxShadow: "0 1px 2px rgba(0,0,0,.05), 0 3px 10px rgba(0,0,0,.05)" }}>
                    <span className="num w-[46px] shrink-0 text-[13.5px] font-semibold tracking-tight text-ink">{c.time}</span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-1.5 text-[13.5px] font-bold tracking-tight text-ink">
                        <Mark tier={c.tier} mine={c.mine} /> <span className="truncate">{c.class_name}</span>
                      </span>
                      <span className="mt-0.5 block text-[11px] text-ink-3">
                        {c.room ? `${c.room} · ` : ""}{c.duration_minutes} min
                      </span>
                    </span>
                    {c.mine ? (
                      <span className="shrink-0 rounded-full px-3.5 py-2 text-[11.5px] font-bold"
                            style={{ background: "var(--accent-chip)", color: "var(--lime-text)" }}>Yours</span>
                    ) : over ? (
                      <button type="button" onClick={() => setSheet({ row: c, over: true })}
                              className="m-tap shrink-0 rounded-full px-3.5 py-2 text-[11.5px] font-bold text-ink-3"
                              style={{ background: "var(--paper)" }}>{coreCap} of {coreCap}</button>
                    ) : (
                      <button type="button" onClick={() => setSheet({ row: c, over: false })}
                              className="m-tap shrink-0 rounded-full px-3.5 py-2 text-[11.5px] font-bold"
                              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Commit</button>
                    )}
                  </li>
                );
              })}
            </ul>

            {dayRest.length > 0 && (
              !showAll ? (
                <button type="button" onClick={() => setShowAll(true)}
                        className="m-tap px-1 text-[12.5px] text-ink-3 underline underline-offset-4">
                  Show {dayRest.length} more you cannot take here
                </button>
              ) : (
                <ul>
                  {dayRest.map((c) => (
                    <li key={c.id} className="mb-2 flex items-center gap-2.5 rounded-2xl bg-[color:var(--surface)] px-3 py-2.5 opacity-80"
                        style={{ boxShadow: "0 1px 2px rgba(0,0,0,.05)" }}>
                      <span className="num w-[46px] shrink-0 text-[13.5px] text-ink-2">{c.time}</span>
                      <span className="min-w-0 flex-1">
                        <span className="flex items-center gap-1.5 text-[13.5px] font-semibold text-ink-2">
                          <Mark tier={c.tier} mine={false} /> <span className="truncate">{c.class_name}</span>
                        </span>
                        <span className="mt-0.5 block text-[11px] text-ink-3">
                          {[!c.qualified && "not one you are down to teach",
                            c.clashes && "clashes with another you are taking",
                            !c.available && "outside the hours you gave us"].filter(Boolean).join(" · ")}
                        </span>
                      </span>
                    </li>
                  ))}
                </ul>
              )
            )}
          </>
        )}
      </div>

      {/* The footnote — generated from the studio's settings, guarantees off = none. */}
      {terms && (terms.guarantees_enabled || terms.flex_enabled) && (
        <div className="mt-4 rounded-2xl border border-line bg-[color:var(--paper)] px-4 py-3 text-[11px] leading-[16px] text-ink-2">
          {terms.guarantees_enabled && (
            <p className="mb-1.5">
              <b className="text-ink">Core</b> — once one person books it runs and you are paid in full, even if they
              cancel late. Nobody booked {terms.core_cutoff_hours ?? 12} hours before, it does not run and you get{" "}
              {terms.holding_cents != null ? money(terms.holding_cents)
                : terms.holding_pct != null ? `${terms.holding_pct}% of your rate` : "the holding fee"}.
            </p>
          )}
          {terms.flex_enabled && (
            <p>
              <b className="text-ink">Flex</b> — you find out{" "}
              {(terms.flex_deadline_mode ?? "previous_day_at") === "previous_day_at"
                ? `by ${terms.flex_deadline_time ?? "20:00"} the night before`
                : `${terms.flex_deadline_hours ?? 12} hours before`}. No booking, no class and no fee, but it sits
              beside a class you are already teaching.
            </p>
          )}
        </div>
      )}

      {sheet && (
        <ClaimSheet
          row={sheet.row} over={sheet.over} cap={coreCap} studioName={studioName}
          whenLabel={`${longDay(sheet.row.date)} · ${sheet.row.time} – ${endTime(sheet.row.time, sheet.row.duration_minutes)}${sheet.row.room ? ` · ${sheet.row.room}` : ""}`}
          onClose={() => setSheet(null)}
        />
      )}
    </div>
  );
}

function ClaimSheet({
  row, over, cap, studioName, whenLabel, onClose,
}: {
  row: ClaimClassRow; over: boolean; cap: number; studioName: string; whenLabel: string; onClose: () => void;
}) {
  const [state, action] = useFormState<ClaimState, FormData>(claimClass, null);
  const core = row.tier === "core";
  const done = state && "ok" in state;
  const pct = cap > 0 ? Math.min(100, Math.round((row.week_core / cap) * 100)) : 0;

  return (
    <div className="fixed inset-0 z-50" role="dialog" aria-modal="true">
      <button aria-label="Close" onClick={onClose} className="absolute inset-0" style={{ background: "rgba(22,19,17,.38)" }} />
      <div className="absolute inset-x-0 bottom-0 rounded-t-3xl bg-[color:var(--surface)] px-5 pb-8 pt-2.5"
           style={{ boxShadow: "0 -10px 44px rgba(22,19,17,.2)" }}>
        <div className="mx-auto mb-4 h-[5px] w-9 rounded-full" style={{ background: "var(--line-2)" }} />

        <span className="mb-3 inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-extrabold uppercase tracking-wider"
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
          <Mark tier={row.tier} mine={false} /> {core ? "Core class" : row.tier === "always" ? "Always runs" : "Flex class"}
        </span>
        <h2 className="text-[21px] font-extrabold leading-tight tracking-tight text-ink">{row.class_name}</h2>
        <p className="num mt-1 text-[13px] font-medium text-ink-2">{whenLabel}</p>

        {done ? (
          <>
            <p className="mt-4 text-[14px] leading-5 text-ink">{(state as { ok: string }).ok}</p>
            <button onClick={onClose} className="mt-4 w-full rounded-2xl py-3.5 text-center text-[15px] font-bold text-ink"
                    style={{ boxShadow: "inset 0 0 0 1.5px var(--line-2)" }}>Done</button>
          </>
        ) : over ? (
          <>
            <div className="my-4 rounded-2xl px-3 py-3 text-[12.5px] leading-[18px]"
                 style={{ background: "#FCF4E3", color: "#6B5313" }}>
              You already have <b style={{ color: "#4A3A0C" }}>{cap} of {cap}</b> core classes that week. You can ask{" "}
              {studioName} to take another, and they will decide.
            </div>
            {state && "error" in state && (
              <p className="mb-2 text-[13px] text-ink" style={{ borderLeft: "3px solid var(--coral, #D9401A)", paddingLeft: 8 }}>{state.error}</p>
            )}
            <form action={action}>
              <input type="hidden" name="occurrence_id" value={row.id} />
              <input type="hidden" name="over_cap_ack" value="1" />
              <button className="w-full rounded-2xl bg-[color:var(--surface)] py-3.5 text-center text-[14px] font-bold"
                      style={{ color: "var(--lime-text)", boxShadow: "inset 0 0 0 1.5px var(--accent-chip)" }}>
                Ask to take it anyway
              </button>
            </form>
            <button onClick={onClose} className="mt-3 w-full text-center text-[13px] font-semibold text-ink-3">Not now</button>
          </>
        ) : (
          <>
            <div className="my-4 rounded-2xl px-3 py-3 text-[12.5px] leading-[18px] text-ink-2" style={{ background: "var(--paper)" }}>
              {core ? (
                <>You are at <b className="text-ink">{row.week_core} of {cap}</b> core classes that week. Committing makes it {row.week_core + 1}.
                  <span className="mt-2.5 block h-1.5 overflow-hidden rounded-full" style={{ background: "var(--line-2)" }}>
                    <span className="block h-full rounded-full" style={{ width: `${pct}%`, background: "var(--accent-solid)" }} />
                  </span>
                </>
              ) : (
                <>This is a {row.tier === "always" ? "class that runs regardless" : "flex class"}. No limit on how many you take.</>
              )}
            </div>
            {state && "error" in state && (
              <p className="mb-2 text-[13px] text-ink" style={{ borderLeft: "3px solid var(--coral, #D9401A)", paddingLeft: 8 }}>{state.error}</p>
            )}
            <form action={action}>
              <input type="hidden" name="occurrence_id" value={row.id} />
              <button className="w-full rounded-2xl py-3.5 text-center text-[15px] font-bold"
                      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                Commit to this class
              </button>
            </form>
            <button onClick={onClose} className="mt-3 w-full text-center text-[13px] font-semibold text-ink-3">Not now</button>
          </>
        )}
      </div>
    </div>
  );
}
