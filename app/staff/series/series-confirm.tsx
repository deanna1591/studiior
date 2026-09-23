"use client";

import { useFormState, useFormStatus } from "react-dom";
import { askSeriesConfirmations, type SeriesState } from "./actions";
import { Notice, buttonQuietClass } from "@/components/ui";

function Ask({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Asking…" : label}</button>;
}

/**
 * Decision 38 — the owner's view of confirmation on a series: "6 of 8 confirmed",
 * and a button to ask the assigned instructor to confirm the ones never asked
 * (classes assigned before the setting turned on). Never blocks the assignment.
 */
export default function SeriesConfirmations({
  seriesId, instructorName, summary,
}: {
  seriesId: string;
  instructorName: string | null;
  summary: { confirmed: number; total: number } | null;
}) {
  const [state, action] = useFormState<SeriesState, FormData>(askSeriesConfirmations, null);
  return (
    <div className="mb-6 max-w-xl rounded border border-line bg-surface px-3.5 py-3">
      <SectionRow>
        <span className="text-[12px] font-medium uppercase tracking-wide text-ink-3">Confirmations</span>
      </SectionRow>
      <p className="mt-1 text-[13px] leading-[19px] text-ink-2">
        {summary
          ? <><span className="num text-ink">{summary.confirmed}</span> of{" "}
              <span className="num text-ink">{summary.total}</span> confirmed
              {instructorName ? <> by {instructorName}</> : null}.</>
          : <>No classes have been sent for confirmation yet.</>}
      </p>
      {state?.error && <div className="mt-2"><Notice kind="error">{state.error}</Notice></div>}
      <form action={action} className="mt-3">
        <input type="hidden" name="series_id" value={seriesId} />
        <Ask label={instructorName ? `Ask ${instructorName} to confirm` : "Ask to confirm"} />
      </form>
    </div>
  );
}

function SectionRow({ children }: { children: React.ReactNode }) {
  return <div className="flex items-center gap-2">{children}</div>;
}
