import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import TimingPanel from "../timing";
import CarryForwardPanel from "../carry-forward";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function InstructorSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Instructors"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const { data: settings } = await supabase.from("studio_settings")
    .select("availability_due_day, week_confirm_escalate_days, carry_forward_enabled, roster_confirm_days")
    .eq("studio_id", ctx.studioId).maybeSingle();

  return (
    <AppShell {...shell} title="Instructors">
      <SettingsBack />
      <SectionLabel>Availability and confirmations</SectionLabel>
      <div className="mt-3"><TimingPanel dueDay={settings?.availability_due_day ?? 20} escalateDays={settings?.week_confirm_escalate_days ?? 3} /></div>
      <div className="mt-8"><SectionLabel>Carry-forward</SectionLabel></div>
      <div className="mt-3">
        <CarryForwardPanel enabled={settings?.carry_forward_enabled ?? false} days={settings?.roster_confirm_days ?? 5} />
      </div>
    </AppShell>
  );
}
