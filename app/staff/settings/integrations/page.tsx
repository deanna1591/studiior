import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import SettingsBack from "../back";
import SettingsSection from "@/components/staff/settings-section";
import SettingsSummaryRow from "@/components/staff/settings-summary";

export const dynamic = "force-dynamic";

/** Decision 71 — Apps & integrations group. Stripe, Xendit and the store apps
 *  keep their own routes (secrets, OAuth, store identifiers); shown here as
 *  summary rows, owner-only (a manager sees them greyed). */
export default async function IntegrationsSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Apps & integrations"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: studio }, { data: xendit }] = await Promise.all([
    supabase.from("studios").select("stripe_account_id, android_package, ios_bundle_id").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_payment_providers").select("test_mode").eq("studio_id", ctx.studioId).eq("provider", "xendit").maybeSingle(),
  ]);
  const owner = ctx.role === "owner";

  const storeState = studio?.android_package || studio?.ios_bundle_id
    ? `${studio?.android_package ? "Android set" : "Android not set"} · ${studio?.ios_bundle_id ? "iPhone set" : "iPhone not set"}`
    : "Not set up yet";

  return (
    <AppShell {...shell} title="Apps & integrations">
      <SettingsBack />

      <SettingsSection id="stripe" title="Card payments (Stripe)">
        <SettingsSummaryRow title="Card payments (Stripe)"
          state={studio?.stripe_account_id ? "Connected." : "Not connected — a studio can take cash instead."}
          href="/settings/stripe" cta={studio?.stripe_account_id ? "Manage" : "Connect"} ownerLocked={!owner} />
      </SettingsSection>

      <SettingsSection id="xendit" title="Xendit">
        <SettingsSummaryRow title="Online payments — Philippines (Xendit)"
          state={xendit ? `Connected · ${xendit.test_mode ? "test mode" : "live mode"}.` : "Not connected."}
          href="/settings/xendit" cta={xendit ? "Manage" : "Connect"} ownerLocked={!owner} />
      </SettingsSection>

      <SettingsSection id="store-apps" title="Store apps">
        <SettingsSummaryRow title="Android & iPhone app verification"
          state={storeState}
          href="/settings/store-apps" cta="Manage" />
      </SettingsSection>
    </AppShell>
  );
}
