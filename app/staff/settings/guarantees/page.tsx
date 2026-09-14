import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import GuaranteesPanel from "../guarantees";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function GuaranteesSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Guarantees"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const { data: settings } = await supabase.from("studio_settings")
    .select("guarantees_enabled, flex_enabled, core_min_bookings, core_cutoff_hours, core_unmet_pay_pct, core_unmet_pay_cents, flex_min_bookings, flex_deadline_mode, flex_deadline_time, flex_deadline_hours, flex_unmet_pay_cents, flex_standby_pay_cents, adjacency_minutes")
    .eq("studio_id", ctx.studioId).maybeSingle();

  return (
    <AppShell {...shell} title="Guarantees & flex">
      <SettingsBack />
      <SectionLabel>Guarantees — when a class runs, and what it owes</SectionLabel>
      <div className="mt-3">
        <GuaranteesPanel currency={ctx.currency ?? "CZK"} s={{
          guarantees_enabled: settings?.guarantees_enabled ?? false,
          flex_enabled: settings?.flex_enabled ?? false,
          core_min_bookings: settings?.core_min_bookings ?? 1,
          core_cutoff_hours: settings?.core_cutoff_hours ?? 12,
          core_unmet_pay_pct: settings?.core_unmet_pay_pct ?? 50,
          core_unmet_pay_cents: settings?.core_unmet_pay_cents ?? null,
          flex_min_bookings: settings?.flex_min_bookings ?? 1,
          flex_deadline_mode: settings?.flex_deadline_mode ?? "previous_day_at",
          flex_deadline_time: settings?.flex_deadline_time ?? "20:00",
          flex_deadline_hours: settings?.flex_deadline_hours ?? 12,
          flex_unmet_pay_cents: settings?.flex_unmet_pay_cents ?? 0,
          flex_standby_pay_cents: settings?.flex_standby_pay_cents ?? 0,
          adjacency_minutes: settings?.adjacency_minutes ?? 90,
        }} />
      </div>
    </AppShell>
  );
}
