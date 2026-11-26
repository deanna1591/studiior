import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../back";
import PromotionsClient, { type PromoRow, type PromoPlan } from "./promotions-client";

export const dynamic = "force-dynamic";

/**
 * Decision 117 — Settings → Promotions. Manager-up. A percent off chosen
 * one-time plans for a date range in studio time. Scheduled ones can be edited;
 * a running one can only be ended; an ended one can be archived.
 */
export default async function PromotionsSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Promotions"><Denied what="promotions" role={ctx.role} /></AppShell>;
  }

  const [{ data: list }, { data: plans }, { data: studio }] = await Promise.all([
    supabase.rpc("promotions_list", { p_studio_id: ctx.studioId }),
    supabase.from("membership_plans").select("id, name, type, price_cents, currency, billing_interval")
      .eq("studio_id", ctx.studioId).neq("status", "archived").order("sort_order"),
    supabase.from("studios").select("currency, timezone").eq("id", ctx.studioId).maybeSingle(),
  ]);
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: ctx.timeZone }).format(new Date());

  return (
    <AppShell {...shell} title="Promotions">
      <SettingsBack />
      <SectionLabel>Promotions</SectionLabel>
      <p className="mt-2 text-[13px]">
        <a href="/settings/promotions/codes" className="font-semibold text-ink underline underline-offset-4">Discount codes</a>
        <span className="text-ink-2">: unique single-use codes, or one shared code.</span>
      </p>
      <p className="mb-4 mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        A percent off chosen packs, drop-ins and the intro offer, for a date range. The plan does
        not change: credits and validity stay the plan&rsquo;s own. Members see the sale price
        with the list price struck through and the tag. Recurring memberships cannot carry a promotion.
      </p>
      <PromotionsClient
        rows={(list ?? []) as PromoRow[]}
        plans={((plans ?? []) as PromoPlan[])}
        currency={studio?.currency ?? "USD"}
        today={today}
      />
    </AppShell>
  );
}
