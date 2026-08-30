import { redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { requireOnboardedStaff, isManagerUp } from "@/lib/auth";
import { Shell, NavLink } from "@/components/ui";
import { PLAN_TYPE_LABEL, formatMoney, type PlanType } from "@/lib/plans";

export const dynamic = "force-dynamic";

export default async function PlansList() {
  const ctx = await requireOnboardedStaff();

  // Permissions §9: creating and editing plans is Owner and Manager. Front desk
  // may VIEW plans because they sell them, but this is the management screen,
  // so it stops here. The refusal that matters is the policy — every write
  // below is refused by plans_manager_write regardless of what this page shows.
  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="Membership plans" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-stone-600">
          Plans are managed by owners and managers. Your role is{" "}
          {ctx.role.replace("_", " ")}.
        </p>
      </Shell>
    );
  }

  const supabase = createClient();
  const [{ data: plans }, { data: memberships }] = await Promise.all([
    supabase
      .from("membership_plans")
      .select("id, name, type, price_cents, currency, status, visibility, credits, credits_per_period, validity_days, billing_interval, sort_order")
      .order("status")
      .order("sort_order")
      .order("name"),
    supabase.from("memberships").select("plan_id, status"),
  ]);

  const live = new Map<string, number>();
  for (const m of memberships ?? []) {
    if (m.status === "cancelled" || m.status === "expired") continue;
    live.set(m.plan_id, (live.get(m.plan_id) ?? 0) + 1);
  }

  const active = (plans ?? []).filter((p) => p.status === "active");
  const archived = (plans ?? []).filter((p) => p.status !== "active");

  const row = (p: NonNullable<typeof plans>[number]) => {
    const n = live.get(p.id) ?? 0;
    const buys =
      p.type === "recurring"
        ? p.credits_per_period === null
          ? "Unlimited"
          : `${p.credits_per_period} per ${p.billing_interval ?? "period"}`
        : `${p.credits ?? "—"} class${p.credits === 1 ? "" : "es"}${p.validity_days ? `, ${p.validity_days}d` : ""}`;
    return (
      <li key={p.id}>
        <Link href={`/plans/${p.id}`}
              className="flex items-center justify-between gap-4 px-3 py-3 hover:bg-stone-50">
          <div className="min-w-0">
            <div className="text-sm font-medium">{p.name}</div>
            <div className="text-xs text-stone-500">
              {PLAN_TYPE_LABEL[p.type as PlanType]} · {buys}
              {p.visibility !== "public" && ` · ${p.visibility.replace("_", " ")}`}
            </div>
          </div>
          <div className="shrink-0 text-right">
            <div className="text-sm">{formatMoney(p.price_cents, p.currency)}</div>
            <div className="text-xs text-stone-500">
              {n === 0 ? "no members" : `${n} member${n === 1 ? "" : "s"}`}
            </div>
          </div>
        </Link>
      </li>
    );
  };

  return (
    <Shell
      title="Membership plans"
      subtitle={`${ctx.studioName} · what the studio sells`}
      right={
        <>
          <NavLink href="/plans/new">New plan</NavLink>
          <NavLink href="/">Back to week</NavLink>
        </>
      }
    >
      {active.length === 0 && (
        <p className="mb-4 text-sm text-stone-500">
          No plans yet. <Link href="/plans/new" className="underline underline-offset-4">Create one</Link>.
        </p>
      )}
      <ul className="divide-y divide-stone-200 rounded border border-stone-200 bg-white">
        {active.map(row)}
      </ul>

      {archived.length > 0 && (
        <>
          <h2 className="mb-2 mt-8 text-sm font-semibold uppercase tracking-wide text-stone-500">
            Archived
          </h2>
          <p className="mb-2 text-xs text-stone-500">
            Not sellable. Members who bought one keep it, at the price they bought at.
          </p>
          <ul className="divide-y divide-stone-200 rounded border border-stone-200 bg-white opacity-70">
            {archived.map(row)}
          </ul>
        </>
      )}
    </Shell>
  );
}
