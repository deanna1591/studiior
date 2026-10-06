import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../back";
import TeamClient, { type TeamRow } from "./team-client";

export const dynamic = "force-dynamic";

/** Decision 70 — Settings → Studio → Team. Owner manages everyone; a manager
 *  invites and removes front desk. Standalone route, linked from /settings/studio. */
export default async function TeamSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Team"><Denied what="the team" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.rpc("studio_team", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as TeamRow[];

  return (
    <AppShell {...shell} title="Team">
      <SettingsBack />
      <SectionLabel>Team</SectionLabel>
      <p className="mb-4 mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Who can sign in to run the studio. An owner invites managers and front
        desk and changes roles; a manager invites and removes front desk.
        Connecting card payments and changing roles stay with owners.
      </p>
      <TeamClient rows={rows} callerRole={ctx.role} />
    </AppShell>
  );
}
