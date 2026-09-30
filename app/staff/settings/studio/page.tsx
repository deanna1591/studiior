import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import OpeningHoursPanel from "../opening-hours";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/**
 * Decision 44 — Settings → Studio. Currently the one opening window; per-weekday
 * hours and closures-by-date are deferred (the existing Closures screen is
 * unchanged).
 */
export default async function StudioSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Studio"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.from("studio_settings")
    .select("open_time, close_time").eq("studio_id", ctx.studioId).maybeSingle();

  // Postgres returns "HH:MM:SS"; a native time input wants "HH:MM".
  const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : null);

  return (
    <AppShell {...shell} title="Studio">
      <SettingsBack />
      <SectionLabel>Opening hours</SectionLabel>
      <div className="mt-3">
        <OpeningHoursPanel open={hhmm(data?.open_time)} close={hhmm(data?.close_time)} />
      </div>
    </AppShell>
  );
}
