import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import PeakPanel from "../peak";
import PeakReport, { type Report } from "../peak-report";
import SuspensionPanel from "../suspension";
import SeatCapsPanel from "../seat-caps";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function FairUseSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Peak & fair use"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: settings }, { count: capped }, { data: peakWindows }, { data: peakPlans }, { data: report }] = await Promise.all([
    supabase.from("studio_settings")
      .select("peak_allowance_enabled, suspension_enabled, suspension_window_days, suspension_warn_at, suspension_at, suspension_days, suspension_repeat_days, peak_cutoff_reminder_minutes, seat_caps_enabled")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("membership_plans").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).not("max_active_members", "is", null),
    supabase.rpc("studio_peak_windows", { p_studio_id: ctx.studioId }),
    supabase.from("membership_plans").select("id, name, peak_allowance, peak_allowance_period").eq("studio_id", ctx.studioId).eq("status", "active").not("peak_allowance", "is", null).order("sort_order"),
    supabase.rpc("peak_allowance_report", { p_studio_id: ctx.studioId, p_days: 90 }),
  ]);

  return (
    <AppShell {...shell} title="Peak & fair use">
      <SettingsBack />
      {report && <PeakReport r={report as unknown as Report} />}

      <section className="mb-10">
        <SectionLabel>Peak hours</SectionLabel>
        <div className="mt-3"><PeakPanel enabled={settings?.peak_allowance_enabled ?? false}
          windows={(peakWindows ?? []).map((w) => ({ id: w.id, day_of_week: w.day_of_week, starts_at: w.starts_at, ends_at: w.ends_at, upcoming: w.upcoming }))}
          plans={(peakPlans ?? []).map((p) => ({ id: p.id, name: p.name, peak_allowance: p.peak_allowance!, peak_allowance_period: p.peak_allowance_period }))} /></div>
      </section>

      <section className="mb-10">
        <SectionLabel>Repeated late cancellations</SectionLabel>
        <div className="mt-3"><SuspensionPanel suspendedNow={(report as unknown as Report | null)?.suspended_now ?? 0} s={{
          suspension_enabled: settings?.suspension_enabled ?? false,
          suspension_window_days: settings?.suspension_window_days ?? 30,
          suspension_warn_at: settings?.suspension_warn_at ?? 2,
          suspension_at: settings?.suspension_at ?? 3,
          suspension_days: settings?.suspension_days ?? 14,
          suspension_repeat_days: settings?.suspension_repeat_days ?? 30,
          peak_cutoff_reminder_minutes: settings?.peak_cutoff_reminder_minutes ?? 120,
        }} /></div>
      </section>

      <section>
        <SectionLabel>Places on a plan</SectionLabel>
        <div className="mt-3"><SeatCapsPanel enabled={settings?.seat_caps_enabled ?? false} capped={capped ?? 0} /></div>
      </section>
    </AppShell>
  );
}
