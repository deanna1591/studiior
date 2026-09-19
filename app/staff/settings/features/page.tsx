import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import ChallengesPanel from "../challenges";
import GuestPassesPanel from "../guest-passes";
import FreeFirstPanel from "../free-first";
import HowToBuyPanel from "../how-to-buy";
import WaiverPanel from "../waiver";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

export default async function FeatureSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Member features"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const [{ data: settings }, { count: challengeCount }, { data: waiver }] = await Promise.all([
    supabase.from("studio_settings").select("challenges_enabled, guest_passes_enabled, free_first_class_enabled, free_first_peak_allowed, how_to_buy").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("challenges").select("id", { count: "exact", head: true }).eq("studio_id", ctx.studioId).eq("audience", "member").limit(1),
    supabase.from("waiver_versions").select("format, requires_resign, created_at, body").eq("studio_id", ctx.studioId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
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
      <section className="mb-10">
        <SectionLabel>Free first class</SectionLabel>
        <div className="mt-3"><FreeFirstPanel
          enabled={settings?.free_first_class_enabled ?? false}
          peakAllowed={settings?.free_first_peak_allowed ?? true} /></div>
      </section>
      <section className="mb-10">
        <SectionLabel>Buying a plan</SectionLabel>
        <div className="mt-3"><HowToBuyPanel value={settings?.how_to_buy ?? null} /></div>
      </section>
      <section>
        <SectionLabel>Waiver</SectionLabel>
        <div className="mt-3"><WaiverPanel current={waiver ?? null} /></div>
      </section>
    </AppShell>
  );
}
