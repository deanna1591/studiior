import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import HorizonPanel from "./horizon";
import TimingPanel from "./timing";

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

  const [{ data: settings }, { count: scheduled }, { data: last }] = await Promise.all([
    supabase.from("studio_settings")
      .select("occurrence_horizon_days, availability_due_day, week_confirm_escalate_days")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("class_occurrences").select("id", { count: "exact", head: true })
      .eq("status", "scheduled").gte("starts_at", new Date().toISOString()),
    supabase.from("class_occurrences").select("starts_at")
      .eq("status", "scheduled").order("starts_at", { ascending: false }).limit(1).maybeSingle(),
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
        <SectionLabel>Instructors</SectionLabel>
        <div className="mt-3">
          <TimingPanel
            dueDay={settings?.availability_due_day ?? 20}
            escalateDays={settings?.week_confirm_escalate_days ?? 3}
          />
        </div>
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
