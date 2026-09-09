"use client";

import { useState } from "react";
import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { previewFill, applyFill, type FillState, type FillRun } from "./actions";

function Btn({ label, tone = "quiet" }: { label: string; tone?: "quiet" | "primary" }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className={`shrink-0 rounded-lg px-3.5 py-2 text-[13px] font-medium disabled:opacity-60 ${
              tone === "primary" ? "bg-ink text-paper" : "text-ink-2"}`}
            style={tone === "quiet" ? { background: "var(--paper)" } : undefined}>
      {pending ? "Working…" : label}
    </button>
  );
}

const monthEnd = (d: Date) => new Date(d.getFullYear(), d.getMonth() + 1, 0);
// From the LOCAL parts, not toISOString(). A Date built at local midnight is
// the previous day in UTC anywhere east of Greenwich, so "next month" opened
// on 30 September instead of 1 October.
const iso = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/**
 * Fill a date range with instructors.
 *
 * THE PREVIEW IS THE POINT. The engine already composes a sentence per class —
 * "3 classes that week, fewest of the candidates", "nobody is down to teach
 * this class type" — and this screen's whole job is to put those in front
 * of somebody before anything is written. A studio that cannot see why
 * Christian got Tuesday and Bo did not will not trust the next run either.
 *
 * Apply is a SECOND, DELIBERATE PRESS and never reachable in one click from the
 * date picker: writing a month of the timetable is not something to discover
 * having done.
 */
export default function FillPanel() {
  const [preview, doPreview] = useFormState<FillState, FormData>(previewFill, null);
  const [applied, doApply] = useFormState<FillState, FormData>(applyFill, null);
  const [open, setOpen] = useState(false);

  const now = new Date();
  const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  const [from, setFrom] = useState(iso(nextMonth));
  const [to, setTo] = useState(iso(monthEnd(nextMonth)));

  // Once applied, the preview is history — what happened is what matters.
  const shown = applied ?? preview;
  const run = shown?.ok ? shown.run : null;
  const isApplied = applied?.ok === true;

  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
              className="rounded-lg px-3.5 py-2 text-[13px] font-medium text-ink-2"
              style={{ background: "var(--paper)" }}>
        Fill a month
      </button>
    );
  }

  return (
    <section className="s-card mb-5 p-5">
      <div className="mb-3 flex items-baseline justify-between gap-3">
        <h2 className="s-head">Fill the timetable</h2>
        <button onClick={() => setOpen(false)} className="text-[12.5px] text-ink-3">Close</button>
      </div>

      <p className="mb-3 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        Assigns an instructor to every open class in the range: somebody down to
        teach that class type, inside the dates they gave you, free at the time,
        and not already teaching. Whoever has fewest classes that week goes
        first — the agreed weekly minimum is how you review an instructor, not
        how the studio staffs a Tuesday. Anything it cannot fill honestly is
        left as an open shift.
      </p>

      <form action={doPreview} className="flex flex-wrap items-end gap-3">
        <label className="text-[12.5px] leading-4 text-ink-2">
          <span className="mb-1 block">From</span>
          <input type="date" name="from" value={from} onChange={(e) => setFrom(e.target.value)}
                 className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
        </label>
        <label className="text-[12.5px] leading-4 text-ink-2">
          <span className="mb-1 block">To</span>
          <input type="date" name="to" value={to} onChange={(e) => setTo(e.target.value)}
                 className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
        </label>
        <Btn label="Preview" tone="primary" />
        <span className="text-[12px] leading-4 text-ink-3">Nothing is written yet.</span>
      </form>

      {shown && !shown.ok && <Notice kind="error">{shown.message}</Notice>}

      {run && <RunReport run={run} applied={isApplied} from={from} to={to} doApply={doApply} />}
    </section>
  );
}

function RunReport({
  run, applied, from, to, doApply,
}: {
  run: FillRun; applied: boolean; from: string; to: string;
  doApply: (fd: FormData) => void;
}) {
  const assigned = run.detail.filter((d) => d.outcome === "assigned");
  const openLeft = run.detail.filter((d) => d.outcome === "left_open");

  return (
    <div className="mt-4">
      <p className="text-[13.5px] leading-[21px] text-ink">
        {applied
          ? <>Done. <strong className="num">{run.assigned}</strong>{" "}
              {run.assigned === 1 ? "class was" : "classes were"} assigned
              {run.left_open > 0 && <>, and <strong className="num">{run.left_open}</strong>{" "}
                {run.left_open === 1 ? "was" : "were"} left as open{" "}
                {run.left_open === 1 ? "shift" : "shifts"}</>}.
            </>
          : <>This would assign <strong className="num">{run.assigned}</strong>{" "}
              {run.assigned === 1 ? "class" : "classes"}
              {run.left_open > 0 && <> and leave <strong className="num">{run.left_open}</strong>{" "}
                open</>}.
            </>}
      </p>

      {/* There is no fallback notice any more, and its absence is the point.
          The engine has one rule — fewest classes that week — so there is no
          second behaviour to fall back FROM. Commitments are a hiring
          expectation the studio reviews people against, not an input here, and
          a banner saying "set their commitment and the next run will aim at it"
          promised something that must not happen. See Decision 18. */}

      {assigned.length > 0 && (
        <div className="mt-4">
          <h3 className="mb-2 text-[12px] font-semibold uppercase leading-4 tracking-[0.06em] text-ink-3">
            {applied ? "Assigned" : "Would assign"}
          </h3>
          <ul>
            {assigned.map((d) => (
              <li key={d.occurrence_id} className="s-row flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
                <span className="num shrink-0 text-[12.5px] leading-5 text-ink-3">{d.when}</span>
                <span className="text-[13.5px] leading-5 text-ink">{d.class}</span>
                <span className="text-[13.5px] font-medium leading-5" style={{ color: "var(--lime-text)" }}>
                  {d.instructor}
                </span>
                {/* The engine's own sentence, unedited. This is the whole
                    reason the panel exists. */}
                <span className="w-full text-[12px] leading-[18px] text-ink-2">{d.why}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {openLeft.length > 0 && (
        <div className="mt-4">
          <h3 className="mb-2 text-[12px] font-semibold uppercase leading-4 tracking-[0.06em] text-ink-3">
            Left open
          </h3>
          <ul>
            {openLeft.map((d) => (
              <li key={d.occurrence_id} className="s-row flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
                <span className="num shrink-0 text-[12.5px] leading-5 text-ink-3">{d.when}</span>
                <span className="text-[13.5px] leading-5 text-ink">{d.class}</span>
                {(d.booked ?? 0) > 0 && (
                  <span className="num text-[12px] leading-5" style={{ color: "var(--coral-deep)" }}>
                    {d.booked} booked
                  </span>
                )}
                <span className="w-full text-[12px] leading-[18px] text-ink-2">{d.why}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {run.detail.length === 0 && (
        <p className="mt-3 text-[13px] leading-[20px] text-ink-2">
          Nothing to fill in that range — every class already has somebody, or
          was assigned by hand and is left alone.
        </p>
      )}

      {applied ? (
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <Link href="/shifts/applications"
                className="text-[13px] font-medium underline underline-offset-4"
                style={{ color: "var(--lime-text)" }}>
            {run.left_open > 0
              ? `See the ${run.left_open} open shift${run.left_open === 1 ? "" : "s"}`
              : "Open shifts"}
          </Link>
          <span className="text-[12px] leading-4 text-ink-3">
            The calendar below is already up to date.
          </span>
        </div>
      ) : (
        <form action={doApply} className="mt-4 flex flex-wrap items-center gap-3">
          <input type="hidden" name="from" value={from} />
          <input type="hidden" name="to" value={to} />
          <Btn label={`Assign ${run.assigned} class${run.assigned === 1 ? "" : "es"}`} tone="primary" />
          <span className="max-w-[46ch] text-[12px] leading-[18px] text-ink-3">
            This runs again rather than replaying the preview, so anything that
            changed in between is taken into account — the result you get is
            what actually happened.
          </span>
        </form>
      )}
    </div>
  );
}
