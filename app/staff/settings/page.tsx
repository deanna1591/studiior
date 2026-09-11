import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import HorizonPanel from "./horizon";
import TimingPanel from "./timing";
import GuaranteesPanel from "./guarantees";
import SeatCapsPanel from "./seat-caps";
import PeakPanel from "./peak";
import PeakReport, { type Report } from "./peak-report";
import SuspensionPanel from "./suspension";

export const dynamic = "force-dynamic";

/**
 * Where the timetable's own settings live.
 *
 * `occurrence_horizon_days` has been a column since migration 057 and no screen
 * has ever read or written it — which is why one studio was carrying 1,421 open
 * classes fourteen months out that any member could book. Two of the three
 * settings here were in the same state.
 */
export default async function Settings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Settings">
        <Denied what="Studio settings" role={ctx.role} />
      </AppShell>
    );
  }

  const [{ data: settings }, { count: scheduled }, { data: last }, { count: capped },
         { data: peakWindows }, { data: peakPlans }, { data: report }] =
    await Promise.all([
    supabase.from("studio_settings")
      // One string literal, not a concatenation: supabase-js infers the row type
      // from the literal, and joining it across lines gives back GenericStringError.
      .select("occurrence_horizon_days, availability_due_day, week_confirm_escalate_days, guarantees_enabled, flex_enabled, seat_caps_enabled, peak_allowance_enabled, suspension_enabled, suspension_window_days, suspension_warn_at, suspension_at, suspension_days, suspension_repeat_days, peak_cutoff_reminder_minutes, core_min_bookings, core_cutoff_hours, core_unmet_pay_pct, flex_min_bookings, flex_deadline_mode, flex_deadline_time, flex_deadline_hours, flex_unmet_pay_cents, flex_standby_pay_cents, adjacency_minutes")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("class_occurrences").select("id", { count: "exact", head: true })
      .eq("status", "scheduled").gte("starts_at", new Date().toISOString()),
    supabase.from("class_occurrences").select("starts_at")
      .eq("status", "scheduled").order("starts_at", { ascending: false }).limit(1).maybeSingle(),
    // Counted here rather than through plan_seats(), which deliberately answers
    // nothing at all while the switch is off — and this line has to be able to
    // say "you have three limits set" to a studio about to turn it back on.
    supabase.from("membership_plans").select("id", { count: "exact", head: true })
      .eq("studio_id", ctx.studioId).not("max_active_members", "is", null),
    // Empty while the peak switch is off, which is what keeps the grid absent
    // rather than drawn and greyed.
    supabase.rpc("studio_peak_windows", { p_studio_id: ctx.studioId }),
    supabase.from("membership_plans")
      .select("id, name, peak_allowance, peak_allowance_period")
      .eq("studio_id", ctx.studioId).eq("status", "active")
      .not("peak_allowance", "is", null).order("sort_order"),
    // Null for a studio using neither switch, so the block is absent rather
    // than a row of dashes.
    supabase.rpc("peak_allowance_report", { p_studio_id: ctx.studioId, p_days: 90 }),
  ]);

  // Formatted on the server: a formatter crossing into a client component is a
  // runtime error TypeScript does not warn about.
  const furthest = last?.starts_at
    ? new Intl.DateTimeFormat("en-GB", {
        day: "numeric", month: "short", year: "numeric", timeZone: ctx.timeZone,
      }).format(new Date(last.starts_at))
    : null;

  return (
    <AppShell {...shell} title="Settings">
      <section className="mb-10">
        <SectionLabel>How far ahead the timetable runs</SectionLabel>
        <div className="mt-3">
          <HorizonPanel
            current={settings?.occurrence_horizon_days ?? 60}
            scheduled={scheduled ?? 0}
            furthest={furthest}
          />
        </div>
      </section>

      <section className="mb-10">
        <SectionLabel>Guarantees — when a class runs, and what it owes</SectionLabel>
        <div className="mt-3">
          <GuaranteesPanel
            currency={ctx.currency ?? "CZK"}
            s={{
              guarantees_enabled: settings?.guarantees_enabled ?? false,
              flex_enabled: settings?.flex_enabled ?? false,
              core_min_bookings: settings?.core_min_bookings ?? 1,
              core_cutoff_hours: settings?.core_cutoff_hours ?? 12,
              core_unmet_pay_pct: settings?.core_unmet_pay_pct ?? 50,
              flex_min_bookings: settings?.flex_min_bookings ?? 1,
              flex_deadline_mode: settings?.flex_deadline_mode ?? "previous_day_at",
              flex_deadline_time: settings?.flex_deadline_time ?? "20:00",
              flex_deadline_hours: settings?.flex_deadline_hours ?? 12,
              flex_unmet_pay_cents: settings?.flex_unmet_pay_cents ?? 0,
              flex_standby_pay_cents: settings?.flex_standby_pay_cents ?? 0,
              adjacency_minutes: settings?.adjacency_minutes ?? 90,
            }}
          />
        </div>
      </section>

      {report && <PeakReport r={report as unknown as Report} />}

      <section className="mb-10">
        <SectionLabel>Peak hours</SectionLabel>
        <div className="mt-3">
          <PeakPanel
            enabled={settings?.peak_allowance_enabled ?? false}
            windows={(peakWindows ?? []).map((w) => ({
              id: w.id, day_of_week: w.day_of_week,
              starts_at: w.starts_at, ends_at: w.ends_at, upcoming: w.upcoming,
            }))}
            plans={(peakPlans ?? []).map((p) => ({
              id: p.id, name: p.name,
              peak_allowance: p.peak_allowance!,
              peak_allowance_period: p.peak_allowance_period,
            }))}
          />
        </div>
      </section>

      <section className="mb-10">
        <SectionLabel>Repeated late cancellations</SectionLabel>
        <div className="mt-3">
          <SuspensionPanel
            suspendedNow={(report as unknown as Report | null)?.suspended_now ?? 0}
            s={{
              suspension_enabled: settings?.suspension_enabled ?? false,
              suspension_window_days: settings?.suspension_window_days ?? 30,
              suspension_warn_at: settings?.suspension_warn_at ?? 2,
              suspension_at: settings?.suspension_at ?? 3,
              suspension_days: settings?.suspension_days ?? 14,
              suspension_repeat_days: settings?.suspension_repeat_days ?? 30,
              peak_cutoff_reminder_minutes: settings?.peak_cutoff_reminder_minutes ?? 120,
            }}
          />
        </div>
      </section>

      <section className="mb-10">
        <SectionLabel>Places on a plan</SectionLabel>
        <div className="mt-3">
          <SeatCapsPanel
            enabled={settings?.seat_caps_enabled ?? false}
            capped={capped ?? 0}
          />
        </div>
      </section>

      <section className="mb-10">
        <SectionLabel>Instructors</SectionLabel>
        <div className="mt-3">
          <TimingPanel
            dueDay={settings?.availability_due_day ?? 20}
            escalateDays={settings?.week_confirm_escalate_days ?? 3}
          />
        </div>
      </section>

      <section className="mb-10">
        <SectionLabel>Closures</SectionLabel>
        <p className="mt-2 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
          Days you are shut — Christmas, a refit, a burst pipe. Nothing is
          generated for them and the member app says you are closed rather than
          showing an empty day.{" "}
          <Link href="/settings/closures" className="text-lime-text underline underline-offset-4">
            Manage closures
          </Link>
        </p>
      </section>

      <section>
        <SectionLabel>Elsewhere</SectionLabel>
        <p className="mt-2 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
          <Link href="/settings/stripe" className="text-lime-text underline underline-offset-4">
            Taking card payments online
          </Link>{" "}
          is its own screen, and what members see —{" "}
          <Link href="/branding" className="text-lime-text underline underline-offset-4">
            colours, logo and photograph
          </Link>{" "}
          — is the owner&rsquo;s.
        </p>
      </section>
    </AppShell>
  );
}
