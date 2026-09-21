import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import HorizonPanel from "../horizon";
import PublicationPanel from "../publication";
import BookingWindowPanel from "../booking-window";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function TimetableSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Timetable"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: settings }, { count: scheduled }, { data: last }, { data: horizon }] = await Promise.all([
    supabase.from("studio_settings").select("occurrence_horizon_days, publication_enabled, booking_window_days").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("class_occurrences").select("id", { count: "exact", head: true }).eq("status", "scheduled").gte("starts_at", new Date().toISOString()),
    supabase.from("class_occurrences").select("starts_at").eq("status", "scheduled").order("starts_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.rpc("timetable_horizon", { p_studio_id: ctx.studioId }),
  ]);
  const hz = horizon as unknown as { months?: string[]; next_unpublished?: string | null } | null;
  const monthLabel = (iso: string) => new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));
  const furthest = last?.starts_at
    ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: ctx.timeZone }).format(new Date(last.starts_at))
    : null;

  return (
    <AppShell {...shell} title="Timetable">
      <SettingsBack />
      <section className="mb-10">
        <SectionLabel>How far ahead the timetable runs</SectionLabel>
        <div className="mt-3"><HorizonPanel current={settings?.occurrence_horizon_days ?? 60} scheduled={scheduled ?? 0} furthest={furthest} /></div>
      </section>
      <section className="mb-10">
        <SectionLabel>How far ahead members can book</SectionLabel>
        <div className="mt-3"><BookingWindowPanel value={settings?.booking_window_days ?? 30} /></div>
      </section>
      <section>
        <SectionLabel>Publishing the month</SectionLabel>
        <div className="mt-3"><PublicationPanel enabled={settings?.publication_enabled ?? false}
          publishedMonths={(hz?.months ?? []).map(monthLabel)} nextDraft={hz?.next_unpublished ? monthLabel(hz.next_unpublished) : null} /></div>
      </section>
    </AppShell>
  );
}
