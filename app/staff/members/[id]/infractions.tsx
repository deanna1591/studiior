"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { excuseInfraction, type ExcuseState } from "./infraction-actions";

export type Infraction = {
  id: string;
  kind: string;
  occurred_at: string;
  occurredLabel: string;
  className: string | null;
  status: string;
  voided_reason: string | null;
};

export type Standing = {
  count: number; warned: boolean; suspended: boolean;
  until: string | null; untilLabel: string | null;
  window_days: number; suspend_at: number; until_suspension: number | null;
};

function Excuse() {
  const { pending } = useFormStatus();
  return (
    <button className="shrink-0 text-[12px] text-ink-2 underline decoration-line-2 underline-offset-4"
            disabled={pending}>
      {pending ? "Excusing…" : "Excuse"}
    </button>
  );
}

/**
 * Decision 24: where a member stands, and the one button that changes it.
 *
 * THE WHOLE SECTION IS ABSENT for a studio not using suspension — `standing` is
 * null there, because `member_suspension()` answers null rather than a shape
 * full of zeroes.
 *
 * Excusing asks for a reason and will not proceed without one. An excuse with no
 * note is a refusal to say why, and the excuse RATE is only worth measuring if
 * each one can be read — it is the number that tells a studio its own threshold
 * is one the desk cannot defend at the counter.
 */
export default function Infractions({ standing, rows }: {
  standing: Standing | null;
  rows: Infraction[];
}) {
  const [state, action] = useFormState<ExcuseState, FormData>(excuseInfraction, null);
  if (!standing) return null;

  return (
    <section className="mt-8">
      <h2 className="border-b border-line pb-1.5 text-[14px] font-medium leading-5 text-ink">
        Late cancellations and no-shows
      </h2>

      {state && <div className="mt-3"><Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice></div>}

      <p className={`mt-3 rounded px-3 py-2 text-[13px] leading-[19px] ${
        standing.suspended ? "border-l-2 border-coral bg-coral-tint text-ink"
        : standing.warned ? "bg-amber-tint text-ink"
        : "text-ink-2"}`}>
        {standing.suspended ? (
          <>
            Advance booking is suspended until{" "}
            <span className="num">{standing.untilLabel}</span>. They can still take a
            place on the day, on whatever is free. Their membership is billed as
            normal throughout — a suspension is not a refund.
          </>
        ) : standing.count === 0 ? (
          <>Nothing in the last <span className="num">{standing.window_days}</span> days.</>
        ) : (
          <>
            <span className="num">{standing.count}</span> in the last{" "}
            <span className="num">{standing.window_days}</span> days
            {standing.until_suspension != null && (
              <>, <span className="num">{standing.until_suspension}</span> more before
              advance booking is suspended</>
            )}
            .
          </>
        )}
      </p>

      <ul className="mt-3 divide-y divide-line">
        {rows.length === 0 && (
          <li className="py-2 text-[13px] text-ink-3">Nothing recorded.</li>
        )}
        {rows.map((r) => (
          <li key={r.id} className="flex items-start justify-between gap-3 py-2">
            <div className="min-w-0">
              <div className={`text-[13px] leading-5 ${r.status === "voided" ? "text-ink-3 line-through" : "text-ink"}`}>
                {r.kind === "no_show" ? "Did not come" : "Cancelled late"}
                {r.className && <> — {r.className}</>}
              </div>
              <div className="text-[12px] leading-4 text-ink-3">
                {r.occurredLabel}
                {r.status === "voided" && r.voided_reason && <> · excused: {r.voided_reason}</>}
              </div>
            </div>
            {r.status === "active" && (
              <form action={action} className="flex shrink-0 items-center gap-2">
                <input type="hidden" name="id" value={r.id} />
                <input name="reason" required placeholder="Why?" aria-label="Reason"
                       className={`${inputClass} w-36 py-1 text-[12px]`} />
                <Excuse />
              </form>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
