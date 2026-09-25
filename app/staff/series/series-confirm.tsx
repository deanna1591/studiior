"use client";

import { useFormState, useFormStatus } from "react-dom";
import { askSeriesConfirmations, markSeriesConfirmed, type SeriesState } from "./actions";
import { Notice, buttonQuietClass } from "@/components/ui";

function Btn({ label, busy }: { label: string; busy: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? busy : label}</button>;
}

/**
 * Decision 38 (+ amendment) — the owner's view of confirmation on a series:
 * "N of M confirmed" split by who confirmed (studio vs instructor), an "Ask
 * {instructor} to confirm" button, and "Mark all confirmed" for classes agreed
 * on paper / assigned before the switch. Never blocks the assignment.
 */
export default function SeriesConfirmations({
  seriesId, instructorName, summary,
}: {
  seriesId: string;
  instructorName: string | null;
  summary: { confirmed: number; total: number; by_studio: number; by_instructor: number } | null;
}) {
  const [askState, askAction] = useFormState<SeriesState, FormData>(askSeriesConfirmations, null);
  const [markState, markAction] = useFormState<SeriesState, FormData>(markSeriesConfirmed, null);
  return (
    <div className="mb-6 max-w-xl rounded border border-line bg-surface px-3.5 py-3">
      <span className="text-[12px] font-medium uppercase tracking-wide text-ink-3">Confirmations</span>
      <p className="mt-1 text-[13px] leading-[19px] text-ink-2">
        {summary
          ? <><span className="num text-ink">{summary.confirmed}</span> of{" "}
              <span className="num text-ink">{summary.total}</span> confirmed
              {summary.confirmed > 0 && (summary.by_studio > 0 || summary.by_instructor > 0)
                ? <> (<span className="num">{summary.by_studio}</span> by the studio,{" "}
                    <span className="num">{summary.by_instructor}</span> by the instructor)</>
                : null}.</>
          : <>No classes have been sent for confirmation yet.</>}
      </p>
      {(askState?.error || markState?.error) && (
        <div className="mt-2"><Notice kind="error">{askState?.error ?? markState?.error}</Notice></div>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        <form action={askAction}>
          <input type="hidden" name="series_id" value={seriesId} />
          <Btn label={instructorName ? `Ask ${instructorName} to confirm` : "Ask to confirm"} busy="Asking…" />
        </form>
        <form action={markAction}>
          <input type="hidden" name="series_id" value={seriesId} />
          <Btn label="Mark all confirmed" busy="Marking…" />
        </form>
      </div>
    </div>
  );
}

function SectionRow({ children }: { children: React.ReactNode }) {
  return <div className="flex items-center gap-2">{children}</div>;
}
