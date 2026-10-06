import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import BookingRulesPanel from "../booking-rules";
import PublicationPanel from "../publication";
import PeakPanel from "../peak";
import PeakReport, { type Report } from "../peak-report";
import SuspensionPanel from "../suspension";
import HideUnstaffedPanel from "../hide-unstaffed";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";
import SettingsSummaryRow from "@/components/staff/settings-summary";

export const dynamic = "force-dynamic";

/** Decision 71 — Booking & cancellation group. The one editor for the booking
 *  window lives here; publication, peak, fair use and hide-unstaffed move in;
 *  the horizon (preview→apply) and the waiver document stay standalone. */
export default async function BookingSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Booking & cancellation"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: s }, horizon, peakWindowsRes, peakPlansRes, reportRes, { data: last }, { data: waiver }] = await Promise.all([
    supabase.from("studio_settings")
      .select("booking_window_days, cancellation_cutoff_minutes, require_waiver, late_cancel_consumes_credit, checkin_opens_minutes_before, checkin_closes_minutes_after, publication_enabled, peak_allowance_enabled, suspension_enabled, suspension_window_days, suspension_warn_at, suspension_at, suspension_days, suspension_repeat_days, peak_cutoff_reminder_minutes, hide_unstaffed_from_members, occurrence_horizon_days")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.rpc("timetable_horizon", { p_studio_id: ctx.studioId }),
    supabase.rpc("studio_peak_windows", { p_studio_id: ctx.studioId }),
    supabase.from("membership_plans").select("id, name, peak_allowance, peak_allowance_period")
      .eq("studio_id", ctx.studioId).eq("status", "active").not("peak_allowance", "is", null).order("sort_order"),
    supabase.rpc("peak_allowance_report", { p_studio_id: ctx.studioId, p_days: 90 }),
    supabase.from("class_occurrences").select("starts_at").eq("status", "scheduled")
      .order("starts_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("waiver_versions").select("format, requires_resign, created_at")
      .eq("studio_id", ctx.studioId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
  ]);

  const hz = horizon.data as unknown as { months?: string[]; next_unpublished?: string | null } | null;
  const monthLabel = (iso: string) => new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));
  const report = reportRes.data as unknown as Report | null;
  const furthest = last?.starts_at
    ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: ctx.timeZone }).format(new Date(last.starts_at))
    : null;

  return (
    <AppShell {...shell} title="Booking & cancellation">
      <SettingsBack />

      <SettingsSection id="booking-rules" title="Booking & cancellation rules">
        <BookingRulesPanel
          windowDays={s?.booking_window_days ?? 30}
          cutoffMinutes={s?.cancellation_cutoff_minutes ?? 720}
          requireWaiver={s?.require_waiver ?? true}
          lateCancelConsumesCredit={s?.late_cancel_consumes_credit ?? true}
          checkinOpensBefore={s?.checkin_opens_minutes_before ?? 60}
          checkinClosesAfter={s?.checkin_closes_minutes_after ?? 30} />
      </SettingsSection>

      <SettingsSection id="publication" title="Publishing the month">
        <PublicationPanel enabled={s?.publication_enabled ?? false}
          publishedMonths={(hz?.months ?? []).map(monthLabel)}
          nextDraft={hz?.next_unpublished ? monthLabel(hz.next_unpublished) : null} />
      </SettingsSection>

      <SettingsSection id="peak" title="Peak hours">
        {report && <div className="mb-4"><PeakReport r={report} /></div>}
        <PeakPanel enabled={s?.peak_allowance_enabled ?? false}
          windows={(peakWindowsRes.data ?? []).map((w) => ({ id: w.id, day_of_week: w.day_of_week, starts_at: w.starts_at, ends_at: w.ends_at, upcoming: w.upcoming }))}
          plans={(peakPlansRes.data ?? []).map((p) => ({ id: p.id, name: p.name, peak_allowance: p.peak_allowance!, peak_allowance_period: p.peak_allowance_period }))} />
      </SettingsSection>

      <SettingsSection id="fair-use" title="Repeated late cancellations">
        <SuspensionPanel suspendedNow={report?.suspended_now ?? 0} s={{
          suspension_enabled: s?.suspension_enabled ?? false,
          suspension_window_days: s?.suspension_window_days ?? 30,
          suspension_warn_at: s?.suspension_warn_at ?? 2,
          suspension_at: s?.suspension_at ?? 3,
          suspension_days: s?.suspension_days ?? 14,
          suspension_repeat_days: s?.suspension_repeat_days ?? 30,
          peak_cutoff_reminder_minutes: s?.peak_cutoff_reminder_minutes ?? 120,
        }} />
      </SettingsSection>

      <SettingsSection id="hide-unstaffed" title="Unstaffed classes">
        <HideUnstaffedPanel enabled={s?.hide_unstaffed_from_members ?? false} />
      </SettingsSection>

      <SettingsSection id="horizon" title="How far ahead classes are generated">
        <SettingsSummaryRow title="Timetable horizon"
          state={`Classes are generated ${s?.occurrence_horizon_days ?? 60} days ahead${furthest ? `, the last on ${furthest}` : ""}.`}
          href="/settings/horizon" cta="Change" />
      </SettingsSection>

      <SettingsSection id="waiver" title="Waiver document">
        <SettingsSummaryRow title="Waiver"
          state={waiver ? `${waiver.format.toUpperCase()}${waiver.requires_resign ? " · re-sign required" : ""} · published ${new Date(waiver.created_at).toLocaleDateString()}` : "No waiver published yet."}
          href="/settings/waiver" cta={waiver ? "Manage" : "Publish"} />
      </SettingsSection>
    </AppShell>
  );
}
