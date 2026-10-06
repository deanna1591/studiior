import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";
import SettingsSummaryRow from "@/components/staff/settings-summary";

export const dynamic = "force-dynamic";

/** Decision 71 — Communications group. The member-app appearance, instructor
 *  names, time format and studio contact all live on the owner-only /branding
 *  page, linked here (greyed "Owner only" for a manager). The campaign sending
 *  domain has no self-serve control. */
export default async function CommunicationsSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Communications"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: studio }, { data: settings }] = await Promise.all([
    supabase.from("studios").select("theme_preset, logo_url, contact_email").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_settings").select("public_instructor_name, time_format").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  const owner = ctx.role === "owner";

  const look = [
    studio?.theme_preset ? `${studio.theme_preset[0].toUpperCase()}${studio.theme_preset.slice(1)} theme` : null,
    studio?.logo_url ? "logo set" : "no logo",
    settings?.time_format === "12h" ? "12-hour" : "24-hour",
    (settings?.public_instructor_name ?? "first") === "full" ? "full names" : "first names",
    studio?.contact_email ? "contact set" : "no contact email",
  ].filter(Boolean).join(" · ");

  return (
    <AppShell {...shell} title="Communications">
      <SettingsBack />

      <SettingsSection id="member-app" title="Member app look & contact">
        <SettingsSummaryRow title="Member app appearance, names, times & contact"
          state={look}
          href="/branding" cta="Open member app" ownerLocked={!owner} />
      </SettingsSection>

      <SettingsSection id="campaign" title="Campaign sending domain">
        <div className="rounded border border-line bg-surface px-3.5 py-3">
          <p className="text-[13px] font-medium text-ink">Campaign sending domain</p>
          <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
            The domain your marketing emails are sent from. Managed by Studiior — contact us to
            move campaigns to your own verified domain. Booking and account emails are unaffected.
          </p>
        </div>
      </SettingsSection>
    </AppShell>
  );
}
