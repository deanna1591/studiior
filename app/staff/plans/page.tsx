import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, Rows, SectionLabel } from "@/components/ui";
import { PLAN_TYPE_LABEL, formatMoney, type PlanType } from "@/lib/plans";

export const dynamic = "force-dynamic";

export default async function PlansList() {
  const screen = await staffScreen("/plans");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Permissions §9: creating and editing plans is Owner and Manager. Front
  // desk sells them, which is a different right, and this is the screen where
  // they are changed. The refusal that counts is plans_manager_write — every
  // write below is refused by the policy whatever this page chooses to show.
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Plans"><Denied what="Managing plans" role={ctx.role} /></AppShell>;
  }

  const [{ data: plans }, { data: memberships }] = await Promise.all([
    supabase
      .from("membership_plans")
      .select("id, name, type, price_cents, currency, status, visibility, credits, credits_per_period, validity_days, billing_interval, sort_order")
      .order("status").order("sort_order").order("name"),
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
          ? "Unlimited classes"
          : `${p.credits_per_period} classes per ${p.billing_interval ?? "period"}`
        : `${p.credits ?? "—"} class${p.credits === 1 ? "" : "es"}${p.validity_days ? `, valid ${p.validity_days} days` : ""}`;
    return (
      <Link
        key={p.id}
        href={`/plans/${p.id}`}
        className={`flex items-center justify-between gap-4 px-3 py-2.5 hover:bg-paper ${
          p.status !== "active" ? "text-ink-3" : ""
        }`}
      >
        <div className="min-w-0">
          <div className={`truncate text-[14px] leading-5 ${p.status === "active" ? "text-ink" : "text-ink-3"}`}>
            {p.name}
          </div>
          <div className="text-[12px] leading-4 text-ink-3">
            {PLAN_TYPE_LABEL[p.type as PlanType]} · {buys}
            {p.visibility !== "public" && ` · ${p.visibility.replace("_", " ")}`}
          </div>
        </div>
        <div className="shrink-0 text-right">
          <div className="num text-[13px] text-ink">{formatMoney(p.price_cents, p.currency)}</div>
          <div className="text-[12px] leading-4 text-ink-3">
            {n === 0 ? "Nobody on it" : <><span className="num">{n}</span> member{n === 1 ? "" : "s"}</>}
          </div>
        </div>
      </Link>
    );
  };

  return (
    <AppShell
      {...shell}
      title="Plans"
      actions={
        <Link
          href="/plans/new"
          className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2"
        >
          Add a plan
        </Link>
      }
    >
      <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        What the studio sells. Changing a plan&rsquo;s price never reprices
        anyone already on it — they keep what they paid at the time — so a
        price rise applies to the next person who buys, not to the people who
        already did.
      </p>

      {active.length === 0 ? (
        <Empty>
          Nothing to sell yet.{" "}
          <Link href="/plans/new" className="text-lime-text underline underline-offset-4">
            Add a plan
          </Link>{" "}
          and members can buy it.
        </Empty>
      ) : (
        <Rows>{active.map(row)}</Rows>
      )}

      {archived.length > 0 && (
        <div className="mt-8">
          <SectionLabel>Archived</SectionLabel>
          <p className="mb-2 text-[12px] leading-4 text-ink-3">
            Not sellable any more. Anyone who bought one keeps it, at the price they bought at.
          </p>
          <Rows>{archived.map(row)}</Rows>
        </div>
      )}
    </AppShell>
  );
}
