"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { fmtTime, fmtDayLong } from "@/lib/time";
import {
  rebookOptions, rebookMember, type RebookOptions, type RebookClass,
} from "../actions";

/**
 * Decision 92 — rebook a member from the roster. The member's row gets a
 * "Rebook" button; it opens a popup with a date strip + month view (days with
 * classes only), the day's classes, and a confirmation card. On success the
 * popup closes, a toast shows, and the row leaves this roster (router.refresh).
 */
export default function RebookButton({
  bookingId, timeZone, timeFormat,
}: { bookingId: string; timeZone: string; timeFormat: "24h" | "12h" }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [opts, setOpts] = useState<RebookOptions | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [view, setView] = useState<"days" | "month">("days");
  const [day, setDay] = useState<string>("");       // YYYY-MM-DD (studio tz)
  const [chosen, setChosen] = useState<RebookClass | null>(null);
  const [result, setResult] = useState<string | null>(null);  // refusal text
  const [pending, start] = useTransition();

  const dayKey = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone });

  useEffect(() => {
    if (!open || opts || loadErr) return;
    (async () => {
      const r = await rebookOptions(bookingId);
      if ("error" in r) { setLoadErr(r.error); return; }
      setOpts(r);
      const first = r.classes[0] ? dayKey(r.classes[0].startsAt) : "";
      setDay(first);
    })();
  }, [open, opts, loadErr, bookingId]);

  // days that have classes, in order
  const days = useMemo(() => {
    const seen = new Map<string, string>(); // key -> first iso that day
    for (const c of opts?.classes ?? []) { const k = dayKey(c.startsAt); if (!seen.has(k)) seen.set(k, c.startsAt); }
    return [...seen.entries()].map(([k, iso]) => ({ key: k, iso }));
  }, [opts]);

  const dayClasses = (opts?.classes ?? []).filter((c) => dayKey(c.startsAt) === day);

  function close() {
    setOpen(false); setOpts(null); setLoadErr(null); setChosen(null); setResult(null); setView("days");
  }

  function confirm() {
    if (!chosen) return;
    setResult(null);
    start(async () => {
      const fd = new FormData();
      fd.set("booking_id", bookingId);
      fd.set("target_id", chosen.id);
      fd.set("class_name", chosen.name);
      const r = await rebookMember(null, fd);
      if (r && r.ok) {
        close();
        // a page-level toast (ToastHost) so it survives the refresh that
        // unmounts this row.
        window.dispatchEvent(new CustomEvent("studiior:toast",
          { detail: `Rebooked to ${r.className}${r.when ? `, ${r.when}` : ""}` }));
        router.refresh();
      } else {
        setResult((r && "message" in r && r.message) || "That couldn’t be done.");
      }
    });
  }

  return (
    <>
      <button onClick={() => setOpen(true)}
        className="mt-1 ml-9 inline-block text-[12px] leading-[18px] underline decoration-line-2 underline-offset-4 hover:decoration-ink"
        style={{ color: "var(--lime-text)" }}>
        Rebook
      </button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true">
          <button aria-label="Close" onClick={close} className="absolute inset-0 bg-black/40" />
          <div className="relative flex max-h-[85vh] w-full max-w-lg flex-col overflow-hidden rounded-t-2xl bg-surface shadow-xl sm:rounded-2xl">
            <div className="flex items-center justify-between border-b border-line px-4 py-3">
              <p className="text-[15px] font-semibold text-ink">
                {chosen ? "Confirm rebooking" : `Rebook ${opts?.firstName ?? ""}`}
              </p>
              <button onClick={close} className="text-[13px] text-ink-2">Close</button>
            </div>

            {/* confirmation card */}
            {chosen ? (
              <div className="flex-1 overflow-y-auto px-4 py-4">
                <div className="rounded-xl border border-line p-4">
                  <p className="text-[15px] font-semibold text-ink">{chosen.name}</p>
                  <p className="mt-1 text-[13px] text-ink-2">{fmtDayLong(chosen.startsAt, timeZone)}, {fmtTime(chosen.startsAt, timeZone, timeFormat)}</p>
                  {chosen.instructorFirst && <p className="text-[13px] text-ink-2">with {chosen.instructorFirst}</p>}
                  <p className="mt-1 text-[12px] text-ink-3"><span className="num">{chosen.seatsLeft}</span> {chosen.seatsLeft === 1 ? "seat" : "seats"} left</p>
                </div>
                <p className="mt-3 text-[13px] leading-[19px] text-ink-2">Their credit or free class moves with the booking.</p>
                <p className="text-[13px] leading-[19px] text-ink-2">{opts?.firstName} will get an email with the new details.</p>
                {result && <p className="mt-3 text-[13px] text-coral">{result}</p>}
                <button onClick={confirm} disabled={pending}
                  className="mt-4 w-full rounded-xl px-4 py-3 text-[15px] font-semibold disabled:opacity-60"
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  {pending ? "Rebooking…" : `Rebook ${opts?.firstName ?? ""}`}
                </button>
                <button onClick={() => { setChosen(null); setResult(null); }} className="mt-2 w-full py-2 text-[13px] text-ink-2">Back</button>
              </div>
            ) : loadErr ? (
              <div className="px-4 py-6 text-[13px] text-coral">{loadErr}</div>
            ) : !opts ? (
              <div className="px-4 py-6 text-[13px] text-ink-3">Loading classes…</div>
            ) : days.length === 0 ? (
              <div className="px-4 py-6 text-[13px] text-ink-3">No upcoming classes to rebook into.</div>
            ) : (
              <>
                {/* view toggle */}
                <div className="flex gap-2 px-4 pt-3">
                  {(["days", "month"] as const).map((v) => (
                    <button key={v} onClick={() => setView(v)}
                      className="rounded-full px-3 py-1 text-[12px] font-semibold"
                      style={view === v ? { background: "var(--accent-chip)", color: "var(--ink)" } : { color: "var(--ink-2)" }}>
                      {v === "days" ? "Days" : "Month"}
                    </button>
                  ))}
                </div>

                {view === "days" ? (
                  <div className="flex gap-1.5 overflow-x-auto px-4 py-3">
                    {days.map((d) => {
                      const on = d.key === day;
                      return (
                        <button key={d.key} onClick={() => setDay(d.key)}
                          className="flex shrink-0 flex-col items-center rounded-lg px-2.5 py-1.5"
                          style={on ? { background: "var(--ink)", color: "var(--surface)" } : { background: "var(--paper)", color: "var(--ink-2)" }}>
                          <span className="text-[10px] uppercase leading-3">{new Date(d.iso).toLocaleDateString("en-GB", { timeZone, weekday: "short" })}</span>
                          <span className="num text-[15px] font-semibold leading-5">{new Date(d.iso).toLocaleDateString("en-GB", { timeZone, day: "numeric" })}</span>
                          <span className="text-[9px] leading-3">{new Date(d.iso).toLocaleDateString("en-GB", { timeZone, month: "short" })}</span>
                        </button>
                      );
                    })}
                  </div>
                ) : (
                  <MonthGrid days={days} selected={day} timeZone={timeZone}
                    onPick={(k) => { setDay(k); setView("days"); }} />
                )}

                {/* the day's classes */}
                <div className="flex-1 overflow-y-auto px-4 pb-5">
                  {dayClasses.length === 0 ? (
                    <p className="py-4 text-[13px] text-ink-3">No classes this day.</p>
                  ) : (
                    <ul className="divide-y divide-line">
                      {dayClasses.map((c) => {
                        const full = c.seatsLeft < 1;
                        return (
                        <li key={c.id} className="flex items-center justify-between gap-3 py-2.5">
                          <span className="min-w-0">
                            <span className="block text-[14px] text-ink">{c.name}</span>
                            <span className="mt-0.5 flex flex-wrap items-center gap-1.5 text-[12px] text-ink-3">
                              <span>
                                {fmtTime(c.startsAt, timeZone, timeFormat)}
                                {c.instructorFirst ? ` · ${c.instructorFirst}` : ""}
                                {` · `}<span className="num">{c.seatsLeft}</span> left
                              </span>
                              {c.tier && (
                                <span className="rounded-full px-2 py-0.5 text-[11px] font-semibold capitalize"
                                      style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                                  {c.tier === "flex" ? "Flex" : "Core"}
                                </span>
                              )}
                              {c.hidden && (
                                <span className="rounded-full border px-1.5 text-[11px] font-medium"
                                      style={{ background: "var(--surface)", color: "var(--ink-2)", borderColor: "var(--line-2)" }}>
                                  Hidden
                                </span>
                              )}
                            </span>
                          </span>
                          <button onClick={() => !full && setChosen(c)} disabled={full}
                            className="shrink-0 rounded-lg border px-2.5 py-1.5 text-[12px] font-semibold disabled:opacity-50"
                            style={{ borderColor: "var(--ink)", color: "var(--ink)" }}>
                            {full ? "Full" : "Rebook to this class"}
                          </button>
                        </li>
                        );
                      })}
                    </ul>
                  )}
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}

function MonthGrid({
  days, selected, timeZone, onPick,
}: { days: { key: string; iso: string }[]; selected: string; timeZone: string; onPick: (k: string) => void }) {
  const have = new Set(days.map((d) => d.key));
  // span the month(s) the classes cover, starting at the first class's month
  const firstIso = days[0]?.iso ?? new Date().toISOString();
  const base = new Date(firstIso);
  const y = Number(base.toLocaleDateString("en-CA", { timeZone, year: "numeric" }));
  const m = Number(base.toLocaleDateString("en-CA", { timeZone, month: "numeric" })) - 1;
  const first = new Date(Date.UTC(y, m, 1));
  const startDow = first.getUTCDay();
  const daysInMonth = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const cells: ({ key: string; n: number } | null)[] = [];
  for (let i = 0; i < startDow; i++) cells.push(null);
  for (let n = 1; n <= daysInMonth; n++) {
    const key = `${y}-${String(m + 1).padStart(2, "0")}-${String(n).padStart(2, "0")}`;
    cells.push({ key, n });
  }
  return (
    <div className="px-4 py-3">
      <p className="mb-2 text-[13px] font-semibold text-ink">
        {first.toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" })}
      </p>
      <div className="grid grid-cols-7 gap-1 text-center">
        {["S", "M", "T", "W", "T", "F", "S"].map((d, i) => <span key={i} className="text-[10px] text-ink-3">{d}</span>)}
        {cells.map((c, i) => c === null ? <span key={i} /> : (
          <button key={i} disabled={!have.has(c.key)} onClick={() => onPick(c.key)}
            className="flex aspect-square flex-col items-center justify-center rounded-lg text-[13px] disabled:opacity-30"
            style={c.key === selected ? { background: "var(--ink)", color: "var(--surface)" }
                   : have.has(c.key) ? { background: "var(--paper)", color: "var(--ink)" } : { color: "var(--ink-3)" }}>
            <span className="num">{c.n}</span>
            {have.has(c.key) && c.key !== selected && <span className="mt-0.5 h-1 w-1 rounded-full" style={{ background: "var(--ink-2)" }} />}
          </button>
        ))}
      </div>
    </div>
  );
}

