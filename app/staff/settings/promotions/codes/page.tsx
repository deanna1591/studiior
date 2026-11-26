import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import CodesClient, { type BatchRow } from "./codes-client";

export const dynamic = "force-dynamic";

/**
 * Decision 120: Settings → Promotions → Discount codes. Manager-up. A batch of
 * unique single-use codes, or one shared code with a maximum number of uses.
 */
export default async function DiscountCodes() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Discount codes"><Denied what="discount codes" role={ctx.role} /></AppShell>;
  }
  const [{ data: list }, { data: plans }, { data: ss }] = await Promise.all([
    supabase.rpc("discount_code_batches_list", { p_studio_id: ctx.studioId }),
    supabase.from("membership_plans").select("id, name").eq("studio_id", ctx.studioId)
      .eq("status", "active").order("sort_order"),
    supabase.from("studio_settings").select("private_sessions_enabled").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: ctx.timeZone }).format(new Date());
  return (
    <AppShell {...shell} title="Discount codes">
      <Link href="/settings/promotions" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">← Promotions</Link>
      <SectionLabel>Discount codes</SectionLabel>
      <p className="mb-4 mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        A percent off chosen plans, class packs, memberships and private sessions, entered at checkout.
        Never on shop items, gift cards or the reservation fee. When a promotion is running, the buyer
        pays the lower of the two, never both.
      </p>
      <CodesClient rows={(list ?? []) as BatchRow[]} plans={(plans ?? []) as { id: string; name: string }[]}
                   privateEnabled={!!ss?.private_sessions_enabled} today={today} />
    </AppShell>
  );
}
