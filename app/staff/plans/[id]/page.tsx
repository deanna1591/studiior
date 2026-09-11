import { notFound, redirect } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, Notice } from "@/components/ui";
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
  const screen = await staffScreen("/plans");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Plans">
        <Denied what="Editing plans" role={ctx.role} />
      </AppShell>
    );
  }

  const { data: plan } = await supabase
    .from("membership_plans")
    .select("*")
    .eq("id", params.id)
    .maybeSingle();
  if (!plan) notFound();

  const [{ data: classTypes }, { count: liveCount }, { data: settings }, { data: seats }] =
    await Promise.all([
      supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
      supabase
        .from("memberships")
        .select("id", { count: "exact", head: true })
        .eq("plan_id", params.id)
        .not("status", "in", "(cancelled,expired)"),
      supabase.from("studio_settings").select("seat_caps_enabled")
        .eq("studio_id", ctx.studioId).maybeSingle(),
      // Decision 24: the seat count comes from plan_seats(), never from the
      // count above. The two happen to agree — "not cancelled and not expired"
      // is the same four statuses plan_seats_taken() counts — and that is
      // exactly why the capped screen must not rely on the coincidence.
      // plan_seats() answers nothing at all while the switch is off.
      supabase.rpc("plan_seats", { p_studio_id: ctx.studioId }),
    ]);

  const active = liveCount ?? 0;
  const seatCaps = settings?.seat_caps_enabled ?? false;
  const taken = (seats ?? []).find((r) => r.plan_id === params.id)?.taken ?? null;

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
    max_active_members: plan.max_active_members,
    show_remaining_below: plan.show_remaining_below,
    on_limit_reached: plan.on_limit_reached,
  };

  return (
    <AppShell {...shell} title={plan.name}
              actions={<NavLink href="/plans">Back to plans</NavLink>}>
      <p className="mb-5 text-[13px] leading-[20px] text-ink-2">
        <span className="num text-ink">{formatMoney(plan.price_cents, plan.currency)}</span>
        {plan.status === "archived"
          ? " · archived, so nobody new can buy it"
          : " · on sale"}
      </p>
      {searchParams.saved && <Notice kind="ok">Saved.</Notice>}
      <PlanForm draft={draft} classTypes={classTypes ?? []} currency={plan.currency}
                activeMemberships={active} mode="edit"
                seatCaps={seatCaps} taken={taken} />
      <PlanLifecycle id={plan.id} status={plan.status} activeMemberships={active} />
    </AppShell>
  );
}
