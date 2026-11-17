import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { conditionLabels, cadenceLine } from "@/lib/campaigns";
import PreviewList from "./preview-list";

export const dynamic = "force-dynamic";

type Audience = {
  id: string; name: string; conditions: Record<string, unknown>;
  template_keys: string[]; cadence_weeks: number; max_weekly: number | null;
  monthly_mode: string; status: string;
};
type Preview = { audience_id: string; name: string; status: string; count: number;
  members: { id: string; first_name: string; last_name: string }[] };
type Result = { audience_id: string; name: string; sent: number; booked: number; bought: number };

/**
 * Decision 112 — weekly campaigns by audience. The studio sees each audience,
 * who it reaches, who it emailed and who came back. Manager-up; the RPCs enforce
 * the same gate. The sweep sends; this screen only shows.
 */
export default async function CampaignsScreen() {
  const screen = await staffScreen("/campaigns");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Campaigns"><Denied what="campaigns" role={ctx.role} /></AppShell>;
  }

  const [{ data: settings }, { data: audData }, { data: prevData }, { data: resData }] = await Promise.all([
    supabase.from("studio_settings").select("weekly_campaigns_enabled").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("campaign_audiences").select("id, name, conditions, template_keys, cadence_weeks, max_weekly, monthly_mode, status")
      .eq("studio_id", ctx.studioId).order("priority", { ascending: true }),
    supabase.rpc("campaign_preview", { p_studio_id: ctx.studioId }),
    supabase.rpc("campaign_results", { p_studio_id: ctx.studioId }),
  ]);

  const on = settings?.weekly_campaigns_enabled ?? false;
  const audiences = (audData ?? []) as Audience[];
  const preview = new Map(((prevData ?? []) as Preview[]).map((p) => [p.audience_id, p]));
  const results = new Map(((resData ?? []) as Result[]).map((r) => [r.audience_id, r]));

  return (
    <AppShell {...shell} title="Campaigns">
      {!on && (
        <div className="mb-4 rounded border border-line bg-amber-tint px-3.5 py-3">
          <p className="text-[13px] text-ink">
            Weekly campaigns are off, so nothing is being sent.{" "}
            <a href="/settings/communications#weekly-campaigns" className="underline decoration-line-2 underline-offset-4 hover:decoration-ink">
              Turn them on in Settings
            </a>{" "}to start.
          </p>
        </div>
      )}

      {audiences.length === 0 ? (
        <p className="text-[13px] text-ink-3">
          No audiences yet. Turn weekly campaigns on in Settings and we'll set up three to start with.
        </p>
      ) : (
        <div className="space-y-4">
          {audiences.map((a) => {
            const p = preview.get(a.id);
            const r = results.get(a.id);
            return (
              <section key={a.id} className="rounded border border-line bg-surface px-3.5 py-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <h2 className="text-[15px] font-semibold text-ink">{a.name}</h2>
                  {a.status !== "active" && (
                    <span className="rounded-full bg-line px-2 py-0.5 text-[11px] text-ink-2">Paused</span>
                  )}
                </div>
                <p className="mt-1 text-[12px] leading-[18px] text-ink-3">
                  {conditionLabels(a.conditions).join(" · ") || "everyone"} · {cadenceLine(a)}
                </p>
                <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-[12px] text-ink-2">
                  <span><span className="font-semibold text-ink">{p?.count ?? 0}</span> in this audience now</span>
                  {r && (
                    <>
                      <span><span className="font-semibold text-ink">{r.sent}</span> emailed (8 wks)</span>
                      <span><span className="font-semibold text-ink">{r.booked}</span> booked after</span>
                      <span><span className="font-semibold text-ink">{r.bought}</span> bought after</span>
                    </>
                  )}
                </div>
                {p && p.count > 0 && <PreviewList members={p.members} count={p.count} />}
              </section>
            );
          })}
        </div>
      )}
    </AppShell>
  );
}
