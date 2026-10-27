import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import Statement from "@/components/member/statement";
import type { StatementRow } from "@/lib/statement";

export const dynamic = "force-dynamic";

/**
 * Decision 75a — the member's itemised activity statement: every booking,
 * cancellation, check-in, no-show, purchase, refund, free class and reschedule,
 * in time order with the credit movement and a running balance (member_activity,
 * which computes the balance from credit_ledger). The two KPI cards stay.
 *
 * Decision 82: bounded to the last 3 months by default, with "Show earlier"
 * loading the rest on demand — a member's whole lifetime was fetched and
 * rendered on every open. The running balance stays correct across the boundary
 * for free: member_activity computes it over the ALL-TIME ledger (the per-row
 * balance is the ledger balance as of that row), so a bounded display window
 * still shows true balances — the opening balance is carried by construction.
 */
export default async function History({
  searchParams,
}: { searchParams: { all?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } = await memberScreen();

  // Default window: the first of the month two months back, in the studio's
  // zone — this month plus the two before it. "Show earlier" (?all=1) loads the
  // whole lifetime.
  const all = searchParams.all === "1";
  const ym = new Intl.DateTimeFormat("en-CA", {
    timeZone: ctx.timeZone, year: "numeric", month: "2-digit",
  }).format(new Date());
  const [y, m] = ym.split("-").map(Number);
  const from = all
    ? "2000-01-01"
    : new Date(Date.UTC(y, m - 1 - 2, 1)).toISOString().slice(0, 10);

  const [{ data: activity }, { data: studio }] = await Promise.all([
    supabase.rpc("member_activity", {
      p_member_id: ctx.memberId, p_from: from, p_to: "2100-01-01",
    }),
    // The studio's currency, for moneyLine's "Unpaid — ₱150 due" (a booked row
    // carries no currency of its own). studios_member_read lets a member read
    // their own studio's row, so this needs no new bootstrap field.
    supabase.from("studios").select("currency").eq("id", ctx.studioId).maybeSingle(),
  ]);
  const rows = (activity ?? []) as StatementRow[];
  const currency = studio?.currency ?? rows.find((r) => r.currency)?.currency ?? "USD";

  // There is older history to load when the window shows fewer visits than the
  // member's lifetime count — no extra query, and it never hides real history.
  const visitsShown = rows.filter((r) => r.kind === "attended").length;
  const moreOlder = !all && visitsShown < ctx.lifetimeVisits;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Your history">
      <div className="mb-5 grid grid-cols-2 gap-3">
        <div className="m-card p-3.5">
          <p className="m-micro text-ink-3">Classes</p>
          <p className="num text-[26px] leading-8 text-ink">{ctx.lifetimeVisits}</p>
        </div>
        <div className="m-card p-3.5">
          <p className="m-micro text-ink-3">Weekly streak</p>
          <p className="num text-[26px] leading-8 text-ink">{ctx.streak}</p>
          {/* Decision 5: weeks, not days. Daily streaks punish rest days, which
              is the opposite of what a Pilates studio wants to encourage. */}
          <p className="m-micro text-ink-3">weeks in a row with a class</p>
        </div>
      </div>

      {!all && (
        <p className="m-micro mb-3 text-ink-3">Showing the last 3 months.</p>
      )}

      <Statement rows={rows} timeZone={ctx.timeZone} timeFormat={ctx.timeFormat} currency={currency} />

      {moreOlder && (
        <Link href="/history?all=1"
              className="m-press mt-4 block rounded-xl border border-line bg-surface px-4 py-3 text-center text-[14px] font-semibold text-ink-2">
          Show earlier
        </Link>
      )}
    </MemberShell>
  );
}
