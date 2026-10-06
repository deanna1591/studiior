import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import BookingRulesPanel from "../booking-rules";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/**
 * Settings → Booking rules (manager-up). The booking window, the cancellation
 * cut-off and the waiver — the same three a studio sets once at /welcome, now
 * editable afterwards — plus whether a late cancellation uses up the credit.
 */
export default async function BookingRulesSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Booking rules"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.from("studio_settings")
    .select("booking_window_days, cancellation_cutoff_minutes, require_waiver, late_cancel_consumes_credit, checkin_opens_minutes_before, checkin_closes_minutes_after")
    .eq("studio_id", ctx.studioId).maybeSingle();

  return (
    <AppShell {...shell} title="Booking rules">
      <SettingsBack />
      <SectionLabel>Booking rules</SectionLabel>
      <div className="mt-3">
        <BookingRulesPanel
          windowDays={data?.booking_window_days ?? 30}
          cutoffMinutes={data?.cancellation_cutoff_minutes ?? 720}
          requireWaiver={data?.require_waiver ?? true}
          lateCancelConsumesCredit={data?.late_cancel_consumes_credit ?? true}
          checkinOpensBefore={data?.checkin_opens_minutes_before ?? 60}
          checkinClosesAfter={data?.checkin_closes_minutes_after ?? 30}
        />
      </div>
    </AppShell>
  );
}
