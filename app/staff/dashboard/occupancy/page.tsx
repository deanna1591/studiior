import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { fmtTime, fmtDayLabel } from "@/lib/time";
import { AppShell, Denied, Empty, Rows } from "@/components/ui";

export const dynamic = "force-dynamic";

/**
 * Decision 86. Where the average-occupancy card lands: every class that ran in
 * the last 30 days, emptiest first — so the owner reads the card's average and
 * then sees which slots are dragging it down. Desk-up.
 */

type Row = {
  occurrence_id: string;
  name: string;
  starts_at: string;
  room: string | null;
  instructor: string | null;
  booked: number;
  capacity: number;
  pct: number | null;
};

export default async function OccupancyPage() {
  const screen = await staffScreen("/dashboard/occupancy");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Occupancy"><Denied what="the schedule" role={ctx.role} /></AppShell>;
  }

  const { data, error } = await supabase.rpc("dashboard_occupancy_30d", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as Row[];

  return (
    <AppShell
      {...shell}
      title="Occupancy, last 30 days"
      actions={
        <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to the dashboard
        </Link>
      }
    >
      {error ? (
        <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            Occupancy could not be read. This is not a studio with no classes.
          </p>
          <p className="num mt-1.5 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      ) : rows.length === 0 ? (
        <Empty>No classes have run in the last 30 days yet.</Empty>
      ) : (
        <Rows>
          {rows.map((r) => (
            <div key={r.occurrence_id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-3 py-2.5">
              <span className="flex min-w-0 flex-col">
                <Link href={`/roster/${r.occurrence_id}`} className="truncate text-[14px] font-medium leading-5 text-ink hover:underline underline-offset-2">
                  {r.name}
                </Link>
                <span className="text-[12px] leading-4 text-ink-3">
                  <span className="num">{fmtDayLabel(r.starts_at, ctx.timeZone)}</span>
                  {" · "}<span className="num">{fmtTime(r.starts_at, ctx.timeZone, ctx.timeFormat)}</span>
                  {r.room && <>{" · "}{r.room}</>}
                  {r.instructor && <>{" · "}{r.instructor}</>}
                </span>
              </span>
              <span className="flex items-baseline gap-2">
                <span className="num text-[14px] font-semibold leading-5 text-ink">{r.pct ?? 0}%</span>
                <span className="num text-[11px] leading-4 text-ink-3">{r.booked}/{r.capacity}</span>
              </span>
            </div>
          ))}
        </Rows>
      )}
    </AppShell>
  );
}
