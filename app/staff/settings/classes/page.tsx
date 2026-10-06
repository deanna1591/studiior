import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import GuaranteesPanel from "../guarantees";
import AutoAssignPanel from "../auto-assign";
import RequireAvailabilityPanel from "../require-availability";
import ClaimingPanel from "../claiming";
import CoverPanel from "../cover";
import TimingPanel from "../timing";
import CarryForwardPanel from "../carry-forward";
import BookingAlertsPanel from "../booking-alerts";
import AssignmentConfirmationsPanel from "../assignment-confirmations";
import ClassRemindersPanel from "../class-reminders";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";

export const dynamic = "force-dynamic";

/** Decision 71 — Classes & instructors group: guarantees/flex, how classes get
 *  staffed, cover, and everything instructors are asked. */
export default async function ClassesSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Classes & instructors"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const { data: s } = await supabase.from("studio_settings")
    .select("guarantees_enabled, flex_enabled, core_min_bookings, core_cutoff_hours, core_unmet_pay_pct, core_unmet_pay_cents, flex_min_bookings, flex_deadline_mode, flex_deadline_time, flex_deadline_hours, flex_unmet_pay_cents, flex_standby_pay_cents, adjacency_minutes, auto_assign_open_classes, assign_requires_availability, claiming_enabled, core_claim_default_cap, cover_auto_accept_enabled, cover_escalation_hours, availability_due_day, week_confirm_escalate_days, week_confirm_enabled, availability_reminders_enabled, carry_forward_enabled, roster_confirm_days, instructor_booking_alerts, assignment_confirmations, instructor_class_reminders")
    .eq("studio_id", ctx.studioId).maybeSingle();

  return (
    <AppShell {...shell} title="Classes & instructors">
      <SettingsBack />

      <SettingsSection id="core" title="Guarantees & flex">
        <GuaranteesPanel currency={ctx.currency ?? "CZK"} s={{
          guarantees_enabled: s?.guarantees_enabled ?? false,
          flex_enabled: s?.flex_enabled ?? false,
          core_min_bookings: s?.core_min_bookings ?? 1,
          core_cutoff_hours: s?.core_cutoff_hours ?? 12,
          core_unmet_pay_pct: s?.core_unmet_pay_pct ?? null,
          core_unmet_pay_cents: s?.core_unmet_pay_cents ?? null,
          flex_min_bookings: s?.flex_min_bookings ?? 1,
          flex_deadline_mode: s?.flex_deadline_mode ?? "previous_day_at",
          flex_deadline_time: s?.flex_deadline_time ?? "20:00",
          flex_deadline_hours: s?.flex_deadline_hours ?? 12,
          flex_unmet_pay_cents: s?.flex_unmet_pay_cents ?? 0,
          flex_standby_pay_cents: s?.flex_standby_pay_cents ?? 0,
          adjacency_minutes: s?.adjacency_minutes ?? 90,
        }} />
      </SettingsSection>

      <SettingsSection id="staffing" title="How classes get staffed">
        <div className="space-y-3">
          <AutoAssignPanel enabled={s?.auto_assign_open_classes ?? false} />
          <RequireAvailabilityPanel enabled={s?.assign_requires_availability ?? false} />
          <ClaimingPanel enabled={s?.claiming_enabled ?? false} defaultCap={s?.core_claim_default_cap ?? 3} />
        </div>
      </SettingsSection>

      <SettingsSection id="cover" title="Cover">
        <CoverPanel enabled={s?.cover_auto_accept_enabled ?? false} hours={s?.cover_escalation_hours ?? 4} />
      </SettingsSection>

      <SettingsSection id="availability" title="Availability & confirmations">
        <TimingPanel
          dueDay={s?.availability_due_day ?? 20}
          escalateDays={s?.week_confirm_escalate_days ?? 3}
          weekConfirm={s?.week_confirm_enabled ?? false}
          availReminders={s?.availability_reminders_enabled ?? false} />
      </SettingsSection>

      <SettingsSection id="carry-forward" title="Carry-forward">
        <CarryForwardPanel enabled={s?.carry_forward_enabled ?? false} days={s?.roster_confirm_days ?? 5} />
      </SettingsSection>

      <SettingsSection id="booking-alerts" title="Booking alerts">
        <BookingAlertsPanel enabled={s?.instructor_booking_alerts ?? false} />
      </SettingsSection>

      <SettingsSection id="assignment-confirmations" title="Assignment confirmations">
        <AssignmentConfirmationsPanel enabled={s?.assignment_confirmations ?? false} />
      </SettingsSection>

      <SettingsSection id="class-reminders" title="Class reminders">
        <ClassRemindersPanel enabled={s?.instructor_class_reminders ?? false} />
      </SettingsSection>
    </AppShell>
  );
}
