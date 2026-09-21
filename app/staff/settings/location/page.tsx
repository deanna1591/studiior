import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import LocationPanel from "../location-panel";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function LocationSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Location"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const { data: loc } = await supabase.from("locations")
    .select("name, address, latitude, longitude, self_checkin_radius_m, self_checkin_accuracy_cap_m, self_checkin_requires_location")
    .eq("studio_id", ctx.studioId).eq("is_primary", true).maybeSingle();

  return (
    <AppShell {...shell} title="Location & self check-in">
      <SettingsBack />
      <SectionLabel>Self check-in</SectionLabel>
      <div className="mt-3">
        <LocationPanel loc={loc ?? null} />
      </div>
    </AppShell>
  );
}
