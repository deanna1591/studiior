"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { setInsightStatus, type BriefState } from "@/app/staff/brief-actions";
import { Notice } from "@/components/ui";
import type { Insight } from "@/components/morning-brief";
import type { Narrative } from "@/lib/dashboard";

/**
 * 4.7 — the insights, as cards with actions.
 *
 * Title, reason, expected impact, one-click action. The insights themselves
 * are migration 023's, unchanged: SQL decides WHO is at risk and WHY, from
 * Decision 14's scoring, which is measurable and testable.
 *
 * WHAT THE MODEL DOES HERE IS CHOOSE WHICH ONE LEADS, and nothing else. It may
 * reorder the set; it may not add to it, and reconcile_dashboard_narratives()
 * refuses an answer naming an insight that was not offered. The lead's
 * sentence sits at the top and its card is pulled out of the list.
 *
 * AN INSIGHT WITHOUT A WORKING BUTTON IS A BUG, not a feature — Business Rules
 * §11 says so — so where the payload carries no href there is no button
 * pretending to be one.
 */
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

function Card({ insight, money, lead }: { insight: Insight; money: string | null; lead?: boolean }) {
  const [state, action] = useFormState<BriefState, FormData>(setInsightStatus, null);
  const href = ((insight.action_payload ?? {}) as { href?: string }).href;
  const edge =
    insight.severity === "urgent" ? "var(--coral)"
    : insight.severity === "warning" ? "var(--amber-deep)" : "var(--ink-3)";

  return (
    <li
      className={`rounded-lg border border-line bg-surface p-3 ${lead ? "shadow-[0_1px_2px_rgb(20_23_14_/_0.05),0_8px_20px_-12px_rgb(20_23_14_/_0.16)]" : ""}`}
      style={{ borderLeft: `3px solid ${edge}` }}
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span className="text-[14px] font-medium leading-5 text-ink">{insight.title}</span>
        {money && (
          <span className="num shrink-0 text-[12px] text-ink-2" title="Estimated impact">
            {money}
          </span>
        )}
      </div>
      <p className="mt-1 text-[13px] leading-[19px] text-ink-2">{insight.observation}</p>
      <p className="mt-1 text-[12px] leading-[17px] text-ink-3">{insight.why_it_matters}</p>

      {state && <div className="mt-2"><Notice kind="error">{state.error}</Notice></div>}

      <div className="mt-2.5 flex flex-wrap items-center gap-4">
        {href ? (
          <Link
            href={href}
            className="rounded bg-ink px-2.5 py-1.5 text-[12px] font-medium leading-4 text-paper hover:bg-ink-2"
          >
            {insight.recommended_action}
          </Link>
        ) : (
          <span className="text-[12px] leading-4 text-ink-3">No screen for this yet.</span>
        )}
        <form action={action} className="contents">
          <StatusButton id={insight.id} status="dismissed" label="Not now" />
        </form>
      </div>
    </li>
  );
}

export default function InsightsPanel({
  insights, money, handled, lead,
}: {
  insights: Insight[];
  money: Record<string, string | null>;
  handled: number;
  lead: Narrative | null;
}) {
  const leadId = lead?.state === "ok" ? lead.lead_insight_id ?? null : null;
  const first = leadId ? insights.find((i) => i.id === leadId) ?? null : null;
  const rest = first ? insights.filter((i) => i.id !== first.id) : insights;

  return (
    <section className="panel">
      <div className="panel-head">
        <h2 className="section-label text-ink-2">Worth your attention</h2>
        {handled > 0 && (
          <span className="text-[11px] leading-4 text-ink-3">
            <span className="num">{handled}</span> handled
          </span>
        )}
      </div>
      <div className="panel-body">
        {insights.length === 0 ? (
          // SAYING NOTHING IS A FEATURE. Some mornings the honest answer is
          // that nothing needs you, and a panel that manufactures five items
          // to look busy trains an owner to stop reading it.
          <div className="rounded-lg border border-line bg-paper px-4 py-5">
            <p className="text-[14px] leading-[21px] text-ink">
              {handled > 0 ? "All of it dealt with." : "Nothing needs you today."}
            </p>
            <p className="mt-1 max-w-[46ch] text-[12px] leading-[17px] text-ink-3">
              {handled > 0
                ? "Anything you handled stays off tomorrow's list for a week."
                : "Members slipping out of their rhythm, classes filling or emptying, and payments that failed all land here, with the one thing that fixes each."}
            </p>
          </div>
        ) : (
          <>
            {first && lead?.text && (
              <p className="mb-3 max-w-[64ch] text-[14px] leading-[21px] text-ink">{lead.text}</p>
            )}
            <ul className="space-y-2.5">
              {first && <Card insight={first} money={money[first.id] ?? null} lead />}
              {rest.map((i) => <Card key={i.id} insight={i} money={money[i.id] ?? null} />)}
            </ul>
          </>
        )}
      </div>
    </section>
  );
}
