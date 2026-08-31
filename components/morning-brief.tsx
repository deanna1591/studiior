"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { setInsightStatus, type BriefState } from "@/app/staff/brief-actions";
import { Notice } from "@/components/ui";

export type Insight = {
  id: string;
  type: string;
  severity: string;
  title: string;
  observation: string;
  why_it_matters: string;
  recommended_action: string;
  action_type: string;
  action_payload: unknown;
  estimated_impact_cents: number | null;
};

/**
 * The Morning Brief.
 *
 * A written summary first, then the items. The summary is the part worth
 * opening: an owner who reads one sentence and closes the tab should still
 * know what today looks like.
 *
 * Nothing here sends anything. Every action is a link to a screen where a
 * person does the thing — Business Rules §11, and the reason the button says
 * what it will open rather than what it will do.
 */
function Dot({ severity }: { severity: string }) {
  const c = severity === "urgent" ? "var(--coral)"
          : severity === "warning" ? "var(--amber-deep)"
          : "var(--ink-3)";
  return <span className="chip-dot mt-[7px]" style={{ background: c }} aria-hidden />;
}

function StatusButton({ id, status, label }: { id: string; status: string; label: string }) {
  const { pending } = useFormStatus();
  return (
    <>
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="status" value={status} />
      <button
        disabled={pending}
        className="text-[12px] leading-4 text-ink-3 underline decoration-line-2 underline-offset-4 hover:text-ink disabled:opacity-50"
      >
        {pending ? "…" : label}
      </button>
    </>
  );
}

function InsightRow({ insight, money, showWhy }: {
  insight: Insight; money: string | null; showWhy: boolean;
}) {
  const [state, action] = useFormState<BriefState, FormData>(setInsightStatus, null);
  const payload = (insight.action_payload ?? {}) as { href?: string };
  const href = payload.href;

  return (
    <li className="flex gap-3 border-b border-line py-3 last:border-0">
      <Dot severity={insight.severity} />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <span className="text-[14px] font-medium leading-5 text-ink">{insight.title}</span>
          {money && <span className="num shrink-0 text-[12px] text-ink-3">{money}</span>}
        </div>
        <p className="mt-0.5 text-[13px] leading-[19px] text-ink-2">{insight.observation}</p>
        {/* Once per type. Four drifting members produced four copies of the
            same sentence, which is four times the words and none of the
            information — the observation above it is what differs. */}
        {showWhy && (
          <p className="mt-1 text-[12px] leading-[17px] text-ink-3">{insight.why_it_matters}</p>
        )}

        {state && <div className="mt-2"><Notice kind="error">{state.error}</Notice></div>}

        <div className="mt-2 flex flex-wrap items-center gap-4">
          {/* An insight without a working button is a bug, not a feature —
              so when the payload has no href there is no button pretending. */}
          {href ? (
            <Link
              href={href}
              className="text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
            >
              {insight.recommended_action}
            </Link>
          ) : (
            <span className="text-[12px] leading-4 text-ink-3">
              No screen for this yet.
            </span>
          )}
          <form action={action} className="contents">
            <StatusButton id={insight.id} status="dismissed" label="Not now" />
          </form>
        </div>
      </div>
    </li>
  );
}

export default function MorningBrief({
  summary, insights, money, dateLabel, handled,
}: {
  summary: string;
  insights: Insight[];
  money: Record<string, string | null>;
  dateLabel: string;
  handled: number;
}) {
  return (
    <section className="mb-8 border-y border-line bg-surface">
      <header className="border-b border-line px-3 py-2.5">
        <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <h2 className="section-label text-ink-2">This morning</h2>
          <span className="text-[11px] leading-4 text-ink-3">
            {dateLabel}
            {handled > 0 && (
              <> · <span className="num">{handled}</span> handled</>
            )}
          </span>
        </div>
        {/* The sentence, not a stat row. */}
        <p className="mt-2 max-w-[64ch] text-[15px] leading-[23px] text-ink">{summary}</p>
      </header>
      {insights.length === 0 && handled > 0 && (
        <p className="px-3 py-3 text-[13px] leading-[19px] text-ink-2">
          All of it dealt with. Anything you handled stays off tomorrow&rsquo;s
          brief for a week.
        </p>
      )}
      {insights.length > 0 && (
        <ul className="px-3">
          {insights.map((i, n) => (
            <InsightRow
              key={i.id}
              insight={i}
              money={money[i.id] ?? null}
              showWhy={insights.findIndex((x) => x.type === i.type) === n}
            />
          ))}
        </ul>
      )}
    </section>
  );
}
