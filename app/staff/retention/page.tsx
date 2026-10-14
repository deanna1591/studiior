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

  const { data } = await supabase.rpc("retention_board", { p_studio_id: ctx.studioId });
  const fmt = (iso: string | null) => {
    if (!iso) return null;
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return `${day} ${month}`;
  };
  const rows: RetentionRow[] = (data ?? []).map((r: any) => ({
    member_id: r.member_id,
    member_name: r.member_name,
    phone: r.phone,
    class_label: fmt(r.class_at) ?? "—",
    days_since: r.days_since,
    instructor_name: r.instructor_name || null,
    offer_label: fmt(r.offer_ends),
    task_id: r.task_id,
    task_status: r.task_status,
    suggested_message: r.suggested_message,
  }));

  return (
    <AppShell {...shell} title="Retention">
      <p className="mb-4 max-w-2xl text-[13px] leading-[20px] text-ink-2">
        Members who took a free class and haven&rsquo;t booked again. Reach out by hand — copy their
        number and the suggested message — then mark them contacted so the sequence stops nagging.
      </p>
      <RetentionBoard rows={rows} />
    </AppShell>
  );
}
