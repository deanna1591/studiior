import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { narrativeFor, revenueWindow, studioToday } from "@/lib/dashboard";
import type { RevenueBlock, Narrative } from "@/lib/dashboard";
import RevenueWidget from "@/components/dashboard/revenue-widget";
import { AppShell, Denied } from "@/components/ui";

export const dynamic = "force-dynamic";

/**
 * Where the revenue card lands. 4.4's own screen, with a custom range as well
 * as the four presets — the dashboard carries the 30-day view, this is where
 * somebody comes to ask a longer question.
 */
export default async function RevenuePage({
  searchParams,
}: {
  searchParams: { rev?: string; from?: string; to?: string };
}) {
  const screen = await staffScreen("/dashboard/revenue");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Revenue"><Denied what="revenue" role={ctx.role} /></AppShell>;
  }

  const today = studioToday(ctx.timeZone);
  const days = revenueWindow(searchParams.rev);
  const isoDate = /^\d{4}-\d{2}-\d{2}$/;
  const custom = isoDate.test(searchParams.from ?? "") && isoDate.test(searchParams.to ?? "");
  const from = custom ? searchParams.from! : studioToday(ctx.timeZone, -(days - 1));
  const to = custom ? searchParams.to! : today;

  const [rev, narrative] = await Promise.all([
    supabase.rpc("dashboard_revenue", { p_studio_id: ctx.studioId, p_from: from, p_to: to }),
    supabase.rpc("dashboard_narrative", { p_studio_id: ctx.studioId, p_kind: "revenue" }),
  ]);

  return (
    <AppShell
      {...shell}
      title="Revenue"
      actions={
        <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to the dashboard
        </Link>
      }
    >
      <RevenueWidget
        r={rev.data as RevenueBlock | null}
        days={custom ? -1 : days}
        narrative={custom ? null : narrativeFor(narrative.data as Narrative | null, days)}
        error={rev.error?.message ?? null}
        hrefFor={(d) => `/dashboard/revenue?rev=${d}`}
      />

      <form className="panel mt-4 p-4" action="/dashboard/revenue">
        <h2 className="section-label mb-2 text-ink-2">A range of your own</h2>
        <div className="flex flex-wrap items-end gap-3">
          <label className="block">
            <span className="mb-1 block text-[12px] leading-4 text-ink-2">From</span>
            <input type="date" name="from" defaultValue={from} max={today}
                   className="rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
          </label>
          <label className="block">
            <span className="mb-1 block text-[12px] leading-4 text-ink-2">To</span>
            <input type="date" name="to" defaultValue={to} max={today}
                   className="rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink" />
          </label>
          <button className="rounded bg-ink px-3 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
            Show it
          </button>
        </div>
        {/* The written sentence describes the 30-day window the cron produced.
            On a custom range it is withheld rather than reused, because a
            sentence about one period sitting over another period's chart is
            the exact disagreement this whole layer exists to prevent. */}
        <p className="mt-2 text-[11px] leading-4 text-ink-3">
          The written summary is about the last 30 days, so it is shown over
          that window and no other — a sentence about one period sitting over
          another period&rsquo;s chart is the disagreement this whole thing
          exists to prevent.
        </p>
      </form>
    </AppShell>
  );
}
