"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Block, BlockEmpty, Narrative } from "@/components/dashboard/block";
import { applyGrowthTier, raiseInstructorBudget, type GrowthState } from "@/app/staff/growth-actions";
import type { GrowthCoach, GrowthSlot, GrowthPayload } from "@/lib/dashboard";

/**
 * Decision 106 — the growth card. Per instructor and weekday, each coach's class
 * slots ranked by a score; every qualifying slot is proposed core (106(a): the
 * weekly budget informs, a slot past it says so and offers to raise it),
 * with a "Make core" / "Make flex" button each. A slot with fewer than four
 * weeks of history shows "Collecting data" with no proposal. Nothing changes
 * without a tap; the RPCs re-check manager-up in the database.
 */

function SubmitPill({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink disabled:opacity-50">
      {pending ? "…" : label}
    </button>
  );
}

export function ApplyForm({ occId, tier, scope, label, raise = false }: {
  occId: string; tier: string; scope: "week" | "series"; label: string; raise?: boolean;
}) {
  const [state, action] = useFormState<GrowthState, FormData>(applyGrowthTier, null);
  return (
    <form action={action} className="contents">
      <input type="hidden" name="occurrence_id" value={occId} />
      <input type="hidden" name="tier" value={tier} />
      <input type="hidden" name="scope" value={scope} />
      {raise && <input type="hidden" name="raise_budget" value="1" />}
      <SubmitPill label={label} />
      {state && "error" in state && <span className="text-[11px] text-coral">{state.error}</span>}
    </form>
  );
}

function RaiseForm({ instructorId, to, coach }: { instructorId: string; to: number; coach: string }) {
  const [state, action] = useFormState<GrowthState, FormData>(raiseInstructorBudget, null);
  return (
    <form action={action} className="mt-1 flex items-center gap-2">
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="n" value={to} />
      <SubmitPill label={`Raise ${coach}’s budget to ${to}`} />
      {state && "error" in state && <span className="text-[11px] text-coral">{state.error}</span>}
    </form>
  );
}

function tierChip(t: "core" | "flex") {
  return (
    <span className="inline-flex items-center rounded-sm border border-line-2 bg-paper px-1.5 py-px text-[11px] leading-4 text-ink-2">
      {t}
    </span>
  );
}

/** Decision 106(a): "Hubert would hold 4 core classes this week, budget 3". */
export function overBudgetLine(coach: string, slot: GrowthSlot, budget: number): string | null {
  if (!slot.over_budget || slot.would_hold == null) return null;
  return `${coach} would hold ${slot.would_hold} core classes this week, budget ${budget}`;
}

function SlotRow({ slot, coach, budget }: { slot: GrowthSlot; coach: string; budget: number }) {
  const over = overBudgetLine(coach, slot, budget);
  const nums = slot.collecting
    ? slot.collecting_label
    : [
        `${slot.avg_booked} of ${slot.capacity} booked`,
        slot.attended_rate != null ? `${Math.round(slot.attended_rate * 100)}% attended` : null,
        `${slot.weeks} wk`,
      ].filter(Boolean).join(" · ");
  return (
    <li className="flex items-start gap-2 border-b border-line py-2">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="num text-[12.5px] text-ink-2">{slot.time}</span>
          <span className="truncate text-[13px] font-medium text-ink">{slot.class_name}</span>
          {tierChip(slot.current_tier)}
          {slot.wanted && (
            <span className="inline-flex items-center rounded-sm border border-line-2 bg-amber-tint px-1.5 py-px text-[11px] leading-4 text-ink">
              in demand
            </span>
          )}
        </div>
        <div className="mt-0.5 text-[12px] text-ink-3">{nums}</div>
        {over && <div className="mt-0.5 text-[12px] text-ink-2">{over}</div>}
      </div>
      <div className="flex shrink-0 flex-col items-end gap-1">
        {slot.action ? (
          <>
            <ApplyForm occId={slot.occurrence_id} tier={slot.proposed_tier!} scope="week"
                       label={slot.action === "make_core" ? "Make core" : "Make flex"} />
            {over && (
              <ApplyForm occId={slot.occurrence_id} tier="core" scope="series" raise
                         label="Make core and raise budget" />
            )}
            <ApplyForm occId={slot.occurrence_id} tier={slot.proposed_tier!} scope="series"
                       label="every week" />
          </>
        ) : slot.collecting ? null : (
          <span className="text-[11px] text-ink-3">keeps {slot.current_tier}</span>
        )}
      </div>
    </li>
  );
}

export function CoachProposals({ coaches }: { coaches: GrowthCoach[] }) {
  if (coaches.length === 0) {
    return <p className="text-[13px] text-ink-2">No recurring classes to review this week.</p>;
  }
  return (
    <div className="space-y-5">
      {coaches.map((c) => (
        <div key={c.instructor_id}>
          <div className="mb-1 flex flex-wrap items-center gap-x-2 gap-y-0.5">
            <h3 className="text-[13px] font-semibold text-ink">{c.name}</h3>
            <span className="text-[12px] text-ink-3">{c.budget} core/week</span>
          </div>
          {c.raise_to && <RaiseForm instructorId={c.instructor_id} to={c.raise_to} coach={c.name} />}
          {c.days.map((d) => (
            <div key={d.dow} className="mt-2">
              <div className="flex items-center gap-2">
                <span className="text-[12px] font-medium text-ink-2">{d.day_name}</span>
              </div>
              <ul>{d.slots.map((s) => <SlotRow key={s.series_id} slot={s} coach={c.name} budget={c.budget} />)}</ul>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

export default function GrowthCard({
  payload, summary, error,
}: {
  payload: GrowthPayload | null;
  summary: string | null;
  error: string | null;
}) {
  return (
    <Block title="Grow your week" error={error}
           hint="Which classes have earned core, which stay flex. Reviewed every Monday.">
      {!payload || payload.coaches.length === 0 ? (
        <BlockEmpty cta={{ href: "/retention#growth", label: "Open Retention" }}>
          The weekly growth review runs on Monday mornings. It will rank each
          coach&rsquo;s classes and propose which earn core.
        </BlockEmpty>
      ) : (
        <>
          {summary && <Narrative text={summary} />}
          <CoachProposals coaches={payload.coaches} />
        </>
      )}
    </Block>
  );
}
