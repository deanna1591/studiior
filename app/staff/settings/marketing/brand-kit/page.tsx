import { staffScreen } from "@/lib/screen";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../../back";
import BrandKit from "@/components/staff/brand-kit";
import { listBrandReferences } from "../actions";
import { defaultSpec, type BrandSpec } from "@/lib/brand-kit";

export const dynamic = "force-dynamic";

/**
 * Settings → Marketing → Brand kit (Decision 93 slice 1). Desk-up may view;
 * front desk read-only (canEdit = manager-up). The page reads the current kit
 * (or the studio defaults) in ONE desk-up call and the references for the
 * uploader; the learn / save / reset writers are all manager-up.
 */
export default async function BrandKitSettings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Brand kit"><Denied what="Brand kit" role={ctx.role} /></AppShell>;
  }
  const canEdit = isManagerUp(ctx.role);

  const { data: cur } = await supabase.rpc("brand_kit_current", { p_studio_id: ctx.studioId });
  const row = (cur ?? {}) as {
    spec?: BrandSpec; source?: string; runs_used?: number; runs_cap?: number;
  };
  const { data: studio } = await supabase.from("studios")
    .select("logo_url, accent_color, theme_preset").eq("id", ctx.studioId).maybeSingle();

  const spec = row.spec ?? defaultSpec({ accent: studio?.accent_color ?? undefined, themePreset: studio?.theme_preset ?? undefined });
  const refs = canEdit ? await listBrandReferences() : [];

  return (
    <AppShell {...shell} title="Brand kit">
      <SettingsBack />
      <SectionLabel>Brand kit</SectionLabel>
      <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Upload a few designs you like, learn your studio&rsquo;s look, and see it on sample timetable posts.
        {canEdit ? "" : " You can view the brand kit; owners and managers edit it."}
      </p>
      <div className="mt-4 max-w-3xl">
        <BrandKit
          initial={{
            spec,
            source: row.source ?? "default",
            runsUsed: row.runs_used ?? 0,
            runsCap: row.runs_cap ?? 10,
          }}
          refs={refs}
          canEdit={canEdit}
          studioName={ctx.studioName}
          logoUrl={studio?.logo_url ?? null}
        />
      </div>
    </AppShell>
  );
}
