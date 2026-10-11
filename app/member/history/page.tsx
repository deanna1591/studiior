import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import Statement from "@/components/member/statement";
import type { StatementRow } from "@/lib/statement";

export const dynamic = "force-dynamic";

/**
 * Decision 75a — the member's itemised activity statement: every booking,
 * cancellation, check-in, no-show, purchase, refund, free class and reschedule,
 * in time order with the credit movement and a running balance (member_activity,
 * which computes the balance from credit_ledger). Replaces the old check-ins
 * list. The two KPI cards stay as context.
 */
export default async function History() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } = await memberScreen();

  const { data: activity } = await supabase.rpc("member_activity", {
    p_member_id: ctx.memberId, p_from: "2000-01-01", p_to: "2100-01-01",
  });

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

      <Statement rows={(activity ?? []) as StatementRow[]} timeZone={ctx.timeZone} timeFormat={ctx.timeFormat} />
    </MemberShell>
  );
}
