import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink, Notice } from "@/components/ui";
import { formatMoney, type PlanType } from "@/lib/plans";
import PlanForm, { type PlanDraft } from "../plan-form";
import PlanLifecycle from "./lifecycle";

export const dynamic = "force-dynamic";

export default async function EditPlan({
  params, searchParams,
}: {
  params: { id: string };
  searchParams: { saved?: string };
}) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);
  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="Plan" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-stone-600">
          Editing plans is owners and managers only. Your role is {ctx.role.replace("_", " ")}.
        </p>
      </Shell>
    );
  }

  const supabase = createClient();
  const { data: plan } = await supabase
    .from("membership_plans")
    .select("*")
    .eq("id", params.id)
    .maybeSingle();
  if (!plan) notFound();

  const [{ data: classTypes }, { count: liveCount }] = await Promise.all([
    supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
    supabase
      .from("memberships")
      .select("id", { count: "exact", head: true })
      .eq("plan_id", params.id)
      .not("status", "in", "(cancelled,expired)"),
  ]);

  const active = liveCount ?? 0;

  const draft: PlanDraft = {
    id: plan.id,
    name: plan.name,
    description: plan.description,
    type: plan.type as PlanType,
    price_cents: plan.price_cents,
    visibility: plan.visibility,
    status: plan.status,
    signup_fee_cents: plan.signup_fee_cents,
    billing_interval: plan.billing_interval,
    billing_interval_count: plan.billing_interval_count,
    credits: plan.credits,
    credits_per_period: plan.credits_per_period,
    validity_days: plan.validity_days,
    commitment_months: plan.commitment_months,
    cancellation_notice_days: plan.cancellation_notice_days,
    freeze_allowed: plan.freeze_allowed,
    max_freeze_days: plan.max_freeze_days,
    booking_window_days: plan.booking_window_days,
    max_bookings_per_day: plan.max_bookings_per_day,
    restrictions: (plan.restrictions as PlanDraft["restrictions"]) ?? null,
  };

  return (
    <Shell
      title={plan.name}
      subtitle={`${formatMoney(plan.price_cents, plan.currency)} · ${plan.status}${plan.status === "archived" ? " — not sellable" : ""}`}
      right={<NavLink href="/plans">Back to plans</NavLink>}
    >
      {searchParams.saved && <Notice kind="ok">Saved.</Notice>}
      <PlanForm draft={draft} classTypes={classTypes ?? []} currency={plan.currency}
                activeMemberships={active} mode="edit" />
      <PlanLifecycle id={plan.id} status={plan.status} activeMemberships={active} />
    </Shell>
  );
}
