import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import WaiverPanel from "./panel";
import SettingsBack from "../back";

export const dynamic = "force-dynamic";

/** Decision 71 — publishing a waiver version stays standalone (versioned text or
 *  PDF upload, re-sign). Linked as a summary from Booking & cancellation; the
 *  "require a signed waiver" toggle itself is in the booking rules. */
export default async function WaiverSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Waiver"><Denied what="Studio settings" role={ctx.role} /></AppShell>;

  const { data: waiver } = await supabase.from("waiver_versions")
    .select("format, requires_resign, created_at, body").eq("studio_id", ctx.studioId)
    .order("created_at", { ascending: false }).limit(1).maybeSingle();

  return (
    <AppShell {...shell} title="Waiver">
      <SettingsBack />
      <SectionLabel>Waiver</SectionLabel>
      <div className="mt-3">
        <WaiverPanel current={waiver ?? null} />
      </div>
    </AppShell>
  );
}
