import { redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { requireOnboardedStaff, isManagerUp } from "@/lib/auth";
import { Shell, NavLink } from "@/components/ui";
import { PLAN_TYPE_LABEL, type PlanType } from "@/lib/plans";
import PlanForm, { type PlanDraft } from "../plan-form";

export const dynamic = "force-dynamic";

const BLANK: PlanDraft = {
  name: "", description: null, type: "recurring", price_cents: null,
  visibility: "public", status: "active", signup_fee_cents: 0,
  billing_interval: "month", billing_interval_count: 1,
  credits: null, credits_per_period: null, validity_days: null,
  commitment_months: 0, cancellation_notice_days: 0,
  freeze_allowed: true, max_freeze_days: null,
  booking_window_days: null, max_bookings_per_day: null, restrictions: null,
};

export default async function NewPlan({
  searchParams,
}: {
  searchParams: { template?: string };
}) {
  const ctx = await requireOnboardedStaff();
  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="New plan" subtitle={ctx.studioName} right={<NavLink href="/plans">Back</NavLink>}>
        <p className="text-sm text-stone-600">
          Creating plans is owners and managers only. Your role is {ctx.role.replace("_", " ")}.
        </p>
      </Shell>
    );
  }

  const supabase = createClient();
  const [{ data: templates }, { data: classTypes }] = await Promise.all([
    supabase
      .from("plan_templates")
      .select("id, name, description, type, billing_interval, billing_interval_count, credits, credits_per_period, validity_days, signup_fee_cents, commitment_months, cancellation_notice_days, freeze_allowed, max_freeze_days, booking_window_days, max_bookings_per_day, restrictions, visibility")
      .order("sort_order"),
    supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
  ]);

  const blank = searchParams.template === "blank";
  const chosen = (templates ?? []).find((t) => t.id === searchParams.template);

  if (blank) {
    return (
      <Shell title="New plan" subtitle={`Blank · ${ctx.studioName}`}
             right={<NavLink href="/plans/new">Start from a template instead</NavLink>}>
        <PlanForm draft={BLANK} classTypes={classTypes ?? []} currency={ctx.currency}
                  activeMemberships={0} mode="create" />
      </Shell>
    );
  }

  // No template picked yet: offer the six, plus starting blank.
  if (!chosen) {
    return (
      <Shell
        title="New plan"
        subtitle="Start from a template, or from nothing"
        right={<NavLink href="/plans">Back to plans</NavLink>}
      >
        <p className="mb-4 max-w-2xl text-sm text-stone-600">
          Every field arrives filled in except the price, which is yours to set —
          a number that reads right in one currency reads badly in another.
          Nothing here is locked: change anything after you pick.
        </p>
        <ul className="divide-y divide-stone-200 rounded border border-stone-200 bg-white">
          {(templates ?? []).map((t) => (
            <li key={t.id}>
              <Link href={`/plans/new?template=${t.id}`}
                    className="block px-3 py-3 hover:bg-stone-50">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-sm font-medium">{t.name}</span>
                  <span className="shrink-0 text-xs text-stone-500">
                    {PLAN_TYPE_LABEL[t.type as PlanType]}
                  </span>
                </div>
                <p className="mt-1 text-xs leading-relaxed text-stone-500">{t.description}</p>
              </Link>
            </li>
          ))}
        </ul>
        <p className="mt-6 text-sm">
          <Link href="/plans/new?template=blank" className="underline underline-offset-4">
            Start from a blank plan instead →
          </Link>
        </p>
      </Shell>
    );
  }

  const draft: PlanDraft = {
    ...BLANK,
    name: chosen.name,
    description: chosen.description,
    type: chosen.type as PlanType,
    billing_interval: chosen.billing_interval,
    billing_interval_count: chosen.billing_interval_count,
    credits: chosen.credits,
    credits_per_period: chosen.credits_per_period,
    validity_days: chosen.validity_days,
    signup_fee_cents: chosen.signup_fee_cents,
    commitment_months: chosen.commitment_months,
    cancellation_notice_days: chosen.cancellation_notice_days,
    freeze_allowed: chosen.freeze_allowed,
    max_freeze_days: chosen.max_freeze_days,
    booking_window_days: chosen.booking_window_days,
    max_bookings_per_day: chosen.max_bookings_per_day,
    restrictions: (chosen.restrictions as PlanDraft["restrictions"]) ?? null,
    visibility: chosen.visibility,
  };

  return (
    <Shell
      title="New plan"
      subtitle={`From the "${chosen.name}" template · ${ctx.studioName}`}
      right={<NavLink href="/plans/new">Pick a different template</NavLink>}
    >
      <PlanForm draft={draft} classTypes={classTypes ?? []} currency={ctx.currency}
                activeMemberships={0} mode="create" />
    </Shell>
  );
}
