"use client";

import { useFormState, useFormStatus } from "react-dom";
import { ApplyForm } from "@/components/dashboard/growth-card";
import { dismissGrowth, type GrowthState } from "@/app/staff/growth-actions";

/** Decision 106(a): the live growth proposal for one class, as schedule_range returns it. */
export type ScheduleGrowth = {
  action: "make_core" | "make_flex";
  proposed_tier: "core" | "flex";
  line: string | null;
  over_budget?: boolean;
  would_hold?: number | null;
  class_occurrence_id: string;
  budget?: number | null;
};

function Pill({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink disabled:opacity-50">
      {pending ? "…" : label}
    </button>
  );
}

function Dismiss({ occId }: { occId: string }) {
  const [state, action] = useFormState<GrowthState, FormData>(dismissGrowth, null);
  if (state && "ok" in state) return <span className="text-[12px] text-ink-3">Hidden for four weeks.</span>;
  return (
    <form action={action} className="contents">
      <input type="hidden" name="occurrence_id" value={occId} />
      <Pill label="Dismiss" />
      {state && "error" in state && <span className="text-[11px] text-coral">{state.error}</span>}
    </form>
  );
}

/** The suggestion line and its buttons, in the class sheet. */
export default function GrowthSuggestion({
  growth, coach, budget,
}: { growth: ScheduleGrowth; coach: string | null; budget: number | null }) {
  const occ = growth.class_occurrence_id;
  const over = growth.over_budget && growth.would_hold != null && budget != null
    ? `${coach ?? "This coach"} would hold ${growth.would_hold} core classes this week, budget ${budget}`
    : null;
  return (
    <div className="mt-3 rounded-lg border px-3 py-2"
         style={{ borderColor: "var(--lime-text)", background: "var(--accent-chip)" }}>
      <p className="text-[13px] leading-[19px] text-ink">
        <span aria-hidden className="mr-1">✦</span>{growth.line ?? (growth.action === "make_core" ? "Make it core?" : "Make it flex?")}
      </p>
      {over && <p className="mt-0.5 text-[12px] leading-[17px] text-ink-2">{over}</p>}
      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        <ApplyForm occId={occ} tier={growth.proposed_tier} scope="week"
                   label={growth.action === "make_core" ? "Make core" : "Make flex"} />
        <ApplyForm occId={occ} tier={growth.proposed_tier} scope="series" label="every week" />
        {over && <ApplyForm occId={occ} tier="core" scope="series" raise label="Make core and raise budget" />}
        <Dismiss occId={occ} />
      </div>
    </div>
  );
}
