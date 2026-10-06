import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import HorizonPanel from "./panel";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/** Decision 71 — the timetable horizon stays standalone (preview→apply, because
 *  shortening it deletes classes). Linked as a summary from Booking & cancellation. */
export default async function HorizonSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Timetable horizon"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: settings }, { count: scheduled }, { data: last }] = await Promise.all([
    supabase.from("studio_settings").select("occurrence_horizon_days").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("class_occurrences").select("id", { count: "exact", head: true }).eq("status", "scheduled").gte("starts_at", new Date().toISOString()),
    supabase.from("class_occurrences").select("starts_at").eq("status", "scheduled").order("starts_at", { ascending: false }).limit(1).maybeSingle(),
  ]);
  const furthest = last?.starts_at
    ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: ctx.timeZone }).format(new Date(last.starts_at))
    : null;

  return (
    <AppShell {...shell} title="Timetable horizon">
      <SettingsBack />
      <SectionLabel>How far ahead the timetable runs</SectionLabel>
      <div className="mt-3">
        <HorizonPanel current={settings?.occurrence_horizon_days ?? 60} scheduled={scheduled ?? 0} furthest={furthest} />
      </div>
    </AppShell>
  );
}
