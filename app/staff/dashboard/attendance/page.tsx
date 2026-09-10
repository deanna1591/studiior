import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { narrativeFor, type HeatmapBlock, type Narrative } from "@/lib/dashboard";
import Heatmap from "@/components/dashboard/heatmap";
import { AppShell, Denied, Segmented } from "@/components/ui";

export const dynamic = "force-dynamic";

const WINDOWS = [30, 90, 180, 365];

/** Where the attendance and occupancy cards land — 4.5 at full size. */
export default async function AttendancePage({
  searchParams,
}: {
  searchParams: { days?: string };
}) {
  const screen = await staffScreen("/dashboard/attendance");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Attendance"><Denied what="attendance" role={ctx.role} /></AppShell>;
  }

  const n = Number(searchParams.days);
  const days = WINDOWS.includes(n) ? n : 90;

  const [hm, narrative] = await Promise.all([
    supabase.rpc("dashboard_heatmap", { p_studio_id: ctx.studioId, p_days: days }),
    supabase.rpc("dashboard_narrative", { p_studio_id: ctx.studioId, p_kind: "attendance" }),
  ]);

  return (
    <AppShell
      {...shell}
      title="Attendance"
      actions={
        <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to the dashboard
        </Link>
      }
      filters={
        <Segmented
          options={WINDOWS.map((d) => ({
            href: `/dashboard/attendance?days=${d}`,
            label: d === 365 ? "1 year" : `${d} days`,
            active: d === days,
          }))}
        />
      }
    >
      <Heatmap
        h={hm.data as HeatmapBlock | null}
        narrative={narrativeFor(narrative.data as Narrative | null, days)}
        error={hm.error?.message ?? null}
      />
    </AppShell>
  );
}
