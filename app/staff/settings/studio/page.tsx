import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { staffMemberOrigin } from "@/lib/member-urls-server";
import OpeningHoursPanel from "../opening-hours";
import LocationPanel from "../location-panel";
import StudioIdentityPanel from "../studio-identity";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";
import SettingsSummaryRow from "@/components/staff/settings-summary";

export const dynamic = "force-dynamic";

/** Decision 71 — Studio group: identity, opening hours, self check-in, and the
 *  standalone check-in code and closures. */
export default async function StudioSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Studio"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const today = new Date().toISOString().slice(0, 10);
  const [{ data: studio }, { data: settings }, { data: loc }, { count: closures }] = await Promise.all([
    supabase.from("studios").select("name, slug, timezone, currency, country").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_settings").select("open_time, close_time").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("locations")
      .select("name, address, latitude, longitude, self_checkin_radius_m, self_checkin_accuracy_cap_m, self_checkin_requires_location")
      .eq("studio_id", ctx.studioId).eq("is_primary", true).maybeSingle(),
    supabase.from("studio_closures").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).gte("ends_on", today),
  ]);

  const origin = await staffMemberOrigin(supabase, studio?.slug ?? "");
  const host = origin.replace(/^https?:\/\//, "");
  const slug = studio?.slug ?? "";
  const memberDomain = host.startsWith(`${slug}.`) ? host.slice(slug.length + 1) : host;
  const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : null);

  return (
    <AppShell {...shell} title="Studio">
      <SettingsBack />

      <SettingsSection id="identity" title="Studio details">
        <StudioIdentityPanel
          name={studio?.name ?? ""} slug={slug} timezone={studio?.timezone ?? ""}
          currency={studio?.currency ?? ""} country={studio?.country ?? null}
          canEditName={isManagerUp(ctx.role)} memberDomain={memberDomain} />
      </SettingsSection>

      <SettingsSection id="team" title="Team">
        <SettingsSummaryRow title="Team access"
          state="Who can sign in to run the studio — invite managers and front desk, change roles, remove access."
          href="/settings/team" cta="Manage team" />
      </SettingsSection>

      <SettingsSection id="opening-hours" title="Opening hours">
        <OpeningHoursPanel open={hhmm(settings?.open_time)} close={hhmm(settings?.close_time)} />
      </SettingsSection>

      <SettingsSection id="location" title="Location & self check-in">
        <LocationPanel loc={loc ?? null} />
      </SettingsSection>

      <SettingsSection id="checkin-code" title="Check-in code">
        <SettingsSummaryRow title="Printable check-in code"
          state="A QR for the wall — members scan it to check in inside the class window."
          href="/settings/studio/checkin-code/print" cta="Print" />
      </SettingsSection>

      <SettingsSection id="closures" title="Closures">
        <SettingsSummaryRow title="Closures & holidays"
          state={(closures ?? 0) === 0 ? "No upcoming closures." : `${closures} upcoming closure${closures === 1 ? "" : "s"}.`}
          href="/settings/closures" cta="Manage" />
      </SettingsSection>
    </AppShell>
  );
}
