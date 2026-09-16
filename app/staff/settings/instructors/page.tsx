import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import TimingPanel from "../timing";
import CarryForwardPanel from "../carry-forward";
import ClaimingPanel from "../claiming";
import CoverPanel from "../cover";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function InstructorSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Instructors"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const { data: settings } = await supabase.from("studio_settings")
    .select("availability_due_day, week_confirm_escalate_days, week_confirm_enabled, availability_reminders_enabled, carry_forward_enabled, roster_confirm_days, claiming_enabled, core_claim_default_cap, cover_auto_accept_enabled, cover_escalation_hours")
    .eq("studio_id", ctx.studioId).maybeSingle();

  return (
    <AppShell {...shell} title="Instructors">
      <SettingsBack />
      <SectionLabel>Availability and confirmations</SectionLabel>
      <div className="mt-3"><TimingPanel
        dueDay={settings?.availability_due_day ?? 20}
        escalateDays={settings?.week_confirm_escalate_days ?? 3}
        weekConfirm={settings?.week_confirm_enabled ?? false}
        availReminders={settings?.availability_reminders_enabled ?? false} /></div>
      <div className="mt-8"><SectionLabel>How classes get staffed</SectionLabel></div>
      <div className="mt-3">
        <ClaimingPanel enabled={settings?.claiming_enabled ?? false} defaultCap={settings?.core_claim_default_cap ?? 3} />
      </div>
      <div className="mt-8"><SectionLabel>Cover</SectionLabel></div>
      <div className="mt-3">
        <CoverPanel enabled={settings?.cover_auto_accept_enabled ?? false} hours={settings?.cover_escalation_hours ?? 4} />
      </div>
      <div className="mt-8"><SectionLabel>Carry-forward</SectionLabel></div>
      <div className="mt-3">
        <CarryForwardPanel enabled={settings?.carry_forward_enabled ?? false} days={settings?.roster_confirm_days ?? 5} />
      </div>
    </AppShell>
  );
}
