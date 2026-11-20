"use client";

import { useMemo, useState, useTransition } from "react";
import { Notice } from "@/components/ui";
import { changeLines, lineError, lineText, outsideWarning, type AvailLine } from "@/lib/availability-edit";
import { editSubmission } from "../my/actions";
import ReviewControls from "./review";

const DAY_OPTS = [1, 2, 3, 4, 5, 6, 0];
const DAY_NAME = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const inp = "rounded-md border border-line-2 bg-surface px-1.5 py-1 text-[13px] text-ink";

/**
 * Decision 18(c)/(d): the submitted hours, inline on the review card, one line
 * per day then one per date, each editable in place. "Save changes" appears next
 * to Approve once something changed. A manager or owner may edit before or after
 * approval and after the cut-off; the database is the boundary.
 */
export default function EditLines({
  submissionId, initial, periodStart, periodEnd, firstName, approved,
}: {
  submissionId: string; initial: AvailLine[]; periodStart: string; periodEnd: string;
  firstName: string; approved: boolean;
}) {
  const [saved, setSaved] = useState<AvailLine[]>(initial);
  const [lines, setLines] = useState<AvailLine[]>(initial);
  const [editing, setEditing] = useState<number | null>(null);
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [warn, setWarn] = useState<string | null>(null);

  const changes = useMemo(() => changeLines(saved, lines), [saved, lines]);
  const dirty = changes.length > 0;
  const days = lines.map((l, i) => ({ l, i })).filter((x) => x.l.day != null);
  const dates = lines.map((l, i) => ({ l, i })).filter((x) => x.l.day == null);

  const set = (i: number, patch: Partial<AvailLine>) =>
    setLines((prev) => prev.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const remove = (i: number) => { setLines((prev) => prev.filter((_, j) => j !== i)); setEditing(null); };
  const add = (l: AvailLine) => { setLines((prev) => [...prev, l]); setEditing(lines.length); };

  function save() {
    const bad = lines.map((l) => lineError(l, periodStart, periodEnd)).find(Boolean);
    if (bad) { setMsg({ ok: false, text: bad }); return; }
    setMsg(null);
    start(async () => {
      const rows = lines.map((l) => (l.day != null
        ? { day: Number(l.day), from: l.from, to: l.to }
        : l.unavailable ? { date: l.date, unavailable: true } : { date: l.date, from: l.from, to: l.to }));
      const r = await editSubmission(submissionId, rows);
      if (!r.ok) { setMsg({ ok: false, text: r.message ?? "That didn't save. Please try again." }); return; }
      setSaved(lines); setEditing(null);
      setWarn(outsideWarning(firstName, r.outside ?? 0));
      setMsg({ ok: true, text: r.notified
        ? `Saved. ${firstName} has been emailed the changes.`
        : `Saved. ${firstName} has no login, so nothing was emailed. Tell them yourself.` });
    });
  }

  const row = ({ l, i }: { l: AvailLine; i: number }) => (
    <li key={i} className="flex flex-wrap items-center gap-1.5 py-0.5 text-[13px] leading-5 text-ink">
      {editing === i ? (
        <>
          {l.day != null ? (
            <select value={String(l.day)} onChange={(e) => set(i, { day: Number(e.target.value) })} className={inp} aria-label="Day">
              {DAY_OPTS.map((d) => <option key={d} value={d}>{DAY_NAME[d]}</option>)}
            </select>
          ) : (
            <input type="date" value={l.date ?? ""} min={periodStart} max={periodEnd}
              onChange={(e) => set(i, { date: e.target.value })} className={inp} aria-label="Date" />
          )}
          {l.unavailable ? <span className="text-ink-2">not available</span> : (
            <>
              <input type="time" step={900} value={l.from ?? ""} onChange={(e) => set(i, { from: e.target.value })} className={inp} aria-label="From" />
              <span className="text-ink-2">to</span>
              <input type="time" step={900} value={l.to ?? ""} onChange={(e) => set(i, { to: e.target.value })} className={inp} aria-label="To" />
            </>
          )}
          {l.day == null && (
            <label className="flex items-center gap-1 text-[12.5px] text-ink-2">
              <input type="checkbox" checked={!!l.unavailable}
                onChange={(e) => set(i, e.target.checked ? { unavailable: true } : { unavailable: false, from: l.from || "09:00", to: l.to || "17:00" })} />
              Not available
            </label>
          )}
          <button type="button" onClick={() => setEditing(null)} className="text-[12.5px] text-ink-2 underline underline-offset-4">Done</button>
        </>
      ) : (
        <button type="button" onClick={() => setEditing(i)} className="num text-left hover:underline" title="Edit this line">
          {lineText(l)}
        </button>
      )}
      <button type="button" onClick={() => remove(i)} aria-label={`Remove ${lineText(l)}`}
        className="ml-1 text-[13px] leading-none text-ink-3 hover:text-ink">×</button>
    </li>
  );

  const saveBtn = dirty ? (
    <button type="button" onClick={save} disabled={pending}
      className="rounded-lg border border-ink px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-50">
      {pending ? "Saving…" : "Save changes"}
    </button>
  ) : null;

  return (
    <div className="mt-2">
      {lines.length === 0 ? (
        <p className="text-[12.5px] leading-[18px] text-ink-3">No hours in this month.</p>
      ) : (
        <ul data-testid="avail-lines">
          {days.map(row)}
          {dates.map(row)}
        </ul>
      )}
      <div className="mt-1 flex flex-wrap gap-3">
        <button type="button" onClick={() => add({ day: 1, from: "09:00", to: "17:00" })}
          className="text-[12.5px] leading-4 text-ink-2 underline underline-offset-4 hover:text-ink">Add a day</button>
        <button type="button" onClick={() => add({ date: periodStart, from: "09:00", to: "17:00" })}
          className="text-[12.5px] leading-4 text-ink-2 underline underline-offset-4 hover:text-ink">Add a date</button>
      </div>
      {dirty && (
        <ul className="mt-1.5 space-y-0.5 text-[12px] leading-4 text-ink-2" aria-label="Changes">
          {changes.map((c) => <li key={c}>{c}</li>)}
        </ul>
      )}
      {warn && (
        <p className="mt-2 border-l-[3px] px-2.5 py-1.5 text-[12.5px] leading-[18px] text-ink"
          style={{ borderLeftColor: "var(--amber-deep)", background: "var(--amber-tint)" }}>{warn}</p>
      )}
      {msg && <div className="mt-2"><Notice kind={msg.ok ? "ok" : "error"}>{msg.text}</Notice></div>}
      {approved ? (saveBtn && <div className="mt-2">{saveBtn}</div>)
        : <ReviewControls submissionId={submissionId} extra={saveBtn} />}
    </div>
  );
}
