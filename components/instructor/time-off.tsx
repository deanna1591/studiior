"use client";

import { useState, useTransition } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { useRouter } from "next/navigation";
import { blockTimeOff, unblockTimeOff, previewTimeOff, setDateHours, clearDateHours } from "@/app/member/instructor/actions";

/**
 * Decision 99 — Time off. The instructor blocks a date or a range they cannot
 * teach (My schedule), and sees their time off as a list with Remove per range.
 * The sheet warns before saving when the dates contain classes they are down to
 * teach; the studio is emailed to arrange cover. Past ranges show without a
 * Remove (a block that already happened is history). The database refuses past
 * dates and a class too close to the swap cut-off.
 */
export type TimeOffRange = {
  from_date: string; to_date: string; reason: string | null;
  is_past: boolean; class_count: number;
};

function fmt(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC", weekday: "short", day: "numeric", month: "short",
  }).format(new Date(`${iso}T00:00:00Z`));
}
function rangeLabel(r: TimeOffRange): string {
  return r.from_date === r.to_date ? fmt(r.from_date) : `${fmt(r.from_date)} to ${fmt(r.to_date)}`;
}

/** Decision 18(d): a single date with its own hours, set outside a submission. */
export type DateHours = { date: string; from: string; to: string };

export default function TimeOff({ ranges, hours = [], instructorId }: {
  ranges: TimeOffRange[]; hours?: DateHours[]; instructorId: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [reason, setReason] = useState("");
  const [warn, setWarn] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  // "off": Not available over a range; "hours": Different hours on one date.
  const [mode, setMode] = useState<"off" | "hours">("off");
  const [hFrom, setHFrom] = useState("09:00");
  const [hTo, setHTo] = useState("17:00");
  const [pending, start] = useTransition();

  async function recount(f: string, t: string) {
    setWarn(null);
    if (!f) return;
    const r = await previewTimeOff(f, t || f);
    if ("count" in r && r.count > 0) setWarn(r.count);
  }

  return (
    <div className="m-card mt-6 px-4 py-4">
      <div className="flex items-center justify-between">
        <h2 className="text-[15px] font-semibold text-ink">Time off</h2>
        {!open && (
          <button onClick={() => { setOpen(true); setMsg(null); }}
            className="rounded-lg border border-line-2 px-3 py-1.5 text-[13px] text-ink-2 hover:text-ink">
            Add time off
          </button>
        )}
      </div>

      {msg && <p className="mt-2 text-[12.5px]" style={{ color: "var(--lime-text)" }}>{msg}</p>}

      {hours.length > 0 && (
        <ul className="mt-3 space-y-1" data-testid="date-hours">
          {hours.map((h) => (
            <li key={h.date} className="flex items-center gap-3 rounded-xl bg-paper px-3.5 py-2.5">
              <span className="min-w-0 flex-1 text-[13px] leading-[18px] text-ink">
                {fmt(h.date)} <span className="text-ink-2">· {h.from} to {h.to}</span>
              </span>
              <button disabled={pending}
                onClick={() => start(async () => {
                  const res = await clearDateHours(instructorId, h.date);
                  if ("ok" in res) { setMsg(res.ok); router.refresh(); } else setErr(res.error);
                })}
                aria-label={`Remove different hours on ${fmt(h.date)}`}
                className="shrink-0 rounded-md px-1.5 py-1 text-[15px] leading-none text-ink-3 disabled:opacity-60">×</button>
            </li>
          ))}
        </ul>
      )}

      {ranges.length === 0 && hours.length === 0 && !open && (
        <p className="mt-2 text-[13px] leading-[20px] text-ink-3">
          No time off. Add a date or a range you cannot teach, and the studio
          arranges cover for any classes in it.
        </p>
      )}

      {ranges.length > 0 && (
        <ul className="mt-3 space-y-1">
          {ranges.map((r) => (
            <li key={`${r.from_date}:${r.reason ?? ""}`}
                className="flex items-center gap-3 rounded-xl bg-paper px-3.5 py-2.5">
              <span className="min-w-0 flex-1 text-[13px] leading-[18px] text-ink">
                {rangeLabel(r)}
                {r.reason && <span className="text-ink-2"> · {r.reason}</span>}
                {r.class_count > 0 && (
                  <span className="mt-0.5 block text-[11.5px] leading-[16px] text-ink-3">
                    {r.class_count} class{r.class_count === 1 ? "" : "es"} the studio is covering
                  </span>
                )}
              </span>
              {!r.is_past && (
                <button disabled={pending}
                  onClick={() => start(async () => {
                    const res = await unblockTimeOff(r.from_date, r.to_date);
                    if ("ok" in res) { setMsg(res.ok); router.refresh(); } else setErr(res.error);
                  })}
                  aria-label={`Remove time off ${rangeLabel(r)}`}
                  className="shrink-0 rounded-md px-1.5 py-1 text-[15px] leading-none text-ink-3 disabled:opacity-60">
                  ×
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {open && (
        <div className="mt-4 border-t border-line pt-4">
          <div className="mb-3 flex gap-2" role="radiogroup" aria-label="Kind of change">
            {(["off", "hours"] as const).map((k) => (
              <button key={k} type="button" role="radio" aria-checked={mode === k}
                onClick={() => { setMode(k); setErr(null); }}
                className="rounded-full px-3.5 py-1.5 text-[13px] font-semibold"
                style={mode === k ? accentSolid() : { background: "var(--accent-chip)", color: "var(--ink)" }}>
                {k === "off" ? "Not available" : "Different hours"}
              </button>
            ))}
          </div>
          {mode === "hours" ? (
            <div className="flex flex-wrap items-end gap-3">
              <label className="text-[13px] text-ink-2">
                <span className="mb-1 block">Date</span>
                <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                  className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
              </label>
              <label className="text-[13px] text-ink-2">
                <span className="mb-1 block">From</span>
                <input type="time" step={900} value={hFrom} onChange={(e) => setHFrom(e.target.value)}
                  className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
              </label>
              <label className="text-[13px] text-ink-2">
                <span className="mb-1 block">To</span>
                <input type="time" step={900} value={hTo} onChange={(e) => setHTo(e.target.value)}
                  className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
              </label>
            </div>
          ) : (
          <div className="flex flex-wrap items-end gap-3">
            <label className="text-[13px] text-ink-2">
              <span className="mb-1 block">From</span>
              <input type="date" value={from}
                onChange={(e) => { setFrom(e.target.value); recount(e.target.value, to); }}
                className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
            </label>
            <label className="text-[13px] text-ink-2">
              <span className="mb-1 block">To</span>
              <input type="date" value={to}
                onChange={(e) => { setTo(e.target.value); recount(from, e.target.value); }}
                className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
            </label>
          </div>
          )}
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason (optional)"
            className="mt-3 w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
          {mode === "off" && warn !== null && (
            <p className="mt-2 text-[12.5px] leading-[18px] text-ink-2">
              You&apos;re down to teach {warn} class{warn === 1 ? "" : "es"} in these dates. The studio will need to cover them.
            </p>
          )}
          {err && <p className="mt-2 text-[12.5px]" style={{ color: "var(--coral-deep)" }}>{err}</p>}
          <div className="mt-3 flex items-center gap-3">
            <button disabled={pending || !from}
              onClick={() => start(async () => {
                setErr(null);
                if (mode === "hours") {
                  const res = await setDateHours(instructorId, from, hFrom, hTo, reason);
                  if ("ok" in res) {
                    setMsg(res.ok); setOpen(false); setFrom(""); setReason(""); router.refresh();
                  } else setErr(res.error);
                  return;
                }
                const fd = new FormData();
                fd.set("from", from); fd.set("to", to || from); fd.set("reason", reason);
                const res = await blockTimeOff(fd);
                if ("ok" in res) {
                  setMsg(res.ok); setOpen(false);
                  setFrom(""); setTo(""); setReason(""); setWarn(null);
                  router.refresh();
                } else setErr(res.error);
              })}
              className="rounded-lg px-3.5 py-2 text-[13px] font-medium disabled:opacity-60"
              style={accentSolid()}>
              {pending ? "Saving…" : "Save"}
            </button>
            <button onClick={() => { setOpen(false); setErr(null); setWarn(null); }}
              className="text-[12.5px] text-ink-2 underline underline-offset-4">Cancel</button>
          </div>
        </div>
      )}
    </div>
  );
}
