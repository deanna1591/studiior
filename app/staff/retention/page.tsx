import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { dayMonthParts } from "@/lib/time";
import { AppShell, Denied } from "@/components/ui";
import RetentionBoard, { type RetentionRow } from "./board";

export const dynamic = "force-dynamic";

/**
 * Decision 78a — "Free class, not yet converted". A member who took their free
 * class and has not bought: their class date, days since, instructor, intro
 * window end, and any open retention task with a copyable Viber message.
 * Manager-up, or a front desk the studio routes tasks to. The RPC enforces the
 * same gate, so a stale page cannot act around it.
 */
export default async function RetentionScreen() {
  const screen = await staffScreen("/retention");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  const manager = isManagerUp(ctx.role);
  const { data: setting } = await supabase.from("studio_settings")
    .select("retention_tasks_to").eq("studio_id", ctx.studioId).maybeSingle();
  const routedToDesk = setting?.retention_tasks_to === "front_desk";
  if (!manager && !(ctx.role === "front_desk" && routedToDesk)) {
    return <AppShell {...shell} title="Retention"><Denied what="retention" role={ctx.role} /></AppShell>;
  }

  const [{ data }, { data: outcomesData }, { data: studio }, { data: aiSetting }] = await Promise.all([
    supabase.rpc("retention_board", { p_studio_id: ctx.studioId }),
    supabase.rpc("retention_outcomes", { p_studio_id: ctx.studioId }),
    supabase.from("studios").select("name").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_settings").select("ai_drafts_enabled").eq("studio_id", ctx.studioId).maybeSingle(),
  ]);
  const aiDrafts = aiSetting?.ai_drafts_enabled ?? false;
  const outcomes = (outcomesData as { contacted: number; came_back: number } | null)
    ?? { contacted: 0, came_back: 0 };
  const fmt = (iso: string | null) => {
    if (!iso) return null;
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return `${day} ${month}`;
  };
  // expires_on is a plain date (no tz); format in UTC so it reads as the day it is.
  const fmtDate = (d: string | null) =>
    d ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" })
          .format(new Date(`${d}T00:00:00Z`)) : null;
  const rows: RetentionRow[] = (data ?? []).map((r: any) => ({
    section: r.section,
    member_id: r.member_id,
    member_name: r.member_name,
    phone: r.phone,
    class_label: fmt(r.class_at) ?? "—",
    days_since: r.days_since,
    instructor_name: r.instructor_name || null,
    offer_label: fmt(r.offer_ends),
    plan_name: r.plan_name ?? null,
    date_label: fmtDate(r.expires_on),
    reason: r.reason ?? null,
    task_id: r.task_id,
    task_status: r.task_status,
    suggested_message: r.suggested_message,
    last_contact_at: r.last_contact_at ?? null,
    last_contact_method: r.last_contact_method ?? null,
    outcome: r.outcome ?? null,
    outcome_days: r.outcome_days ?? null,
  }));

  return (
    <AppShell {...shell} title="Retention">
      <p className="mb-4 max-w-2xl text-[13px] leading-[20px] text-ink-2">
        Who needs a nudge. Click a member to see them and reach out — email, Viber, a call —
        then watch whether they come back.
      </p>
      <RetentionBoard rows={rows} studioId={ctx.studioId}
        studioName={studio?.name ?? "your studio"} aiDrafts={aiDrafts} outcomes={outcomes} />
    </AppShell>
  );
}
