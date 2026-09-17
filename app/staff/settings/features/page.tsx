import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import ChallengesPanel from "../challenges";
import GuestPassesPanel from "../guest-passes";
import FreeFirstPanel from "../free-first";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function FeatureSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Member features"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: settings }, { count: challengeCount }] = await Promise.all([
    supabase.from("studio_settings").select("challenges_enabled, guest_passes_enabled, free_first_class_enabled, free_first_peak_allowed").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("challenges").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).eq("audience", "member").limit(1),
  ]);

  return (
    <AppShell {...shell} title="Member features">
      <SettingsBack />
      <section className="mb-10">
        <SectionLabel>Challenges</SectionLabel>
        <div className="mt-3"><ChallengesPanel enabled={settings?.challenges_enabled ?? false} hasChallenges={(challengeCount ?? 0) > 0} /></div>
      </section>
      <section className="mb-10">
        <SectionLabel>Guest passes</SectionLabel>
        <div className="mt-3"><GuestPassesPanel enabled={settings?.guest_passes_enabled ?? false} /></div>
      </section>
      <section>
        <SectionLabel>Free first class</SectionLabel>
        <div className="mt-3"><FreeFirstPanel
          enabled={settings?.free_first_class_enabled ?? false}
          peakAllowed={settings?.free_first_peak_allowed ?? true} /></div>
      </section>
    </AppShell>
  );
}
