import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import ClassDetailBody from "@/components/member/class-detail-body";
import { loadClassDetail } from "./load";
import { fmtDayLong, fmtTime } from "@/lib/time";
import { formatMoney } from "@/lib/plans";
import ReservedPoll from "@/components/member/reserved-poll";

export const dynamic = "force-dynamic";

/**
 * One class, in full — the full-page form, reached by a direct load, a refresh
 * or a deep link. A tap from inside the app is intercepted and shown as a
 * bottom sheet instead (app/member/@modal/(.)class/[id]); both render the same
 * ClassDetailBody, so they cannot drift.
 */
export default async function ClassDetail({ params, searchParams }: { params: { id: string }; searchParams: { t?: string; reserved?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const data = await loadClassDetail(supabase, ctx.memberId, ctx.studioId, params.id, settings.guestPassesEnabled, searchParams?.t ?? null);
  if (!data) notFound();

  // Decision 103: the reservation return states. After the Xendit return (?reserved=1)
  // the member sees one of three: "You're in" once the webhook confirmed, "Finishing
  // your payment..." while pending, or "Your spot wasn't held" if the window passed.
  let reserved: { state: "confirmed" | "pending" | "lost"; line: string } | null = null;
  if (searchParams?.reserved === "1" && (settings.reservationFeeCents ?? 0) > 0) {
    const [{ data: bk }, { data: pur }] = await Promise.all([
      supabase.from("bookings")
        .select("id, status, payment_source, payments(kind, status)")
        .eq("member_id", ctx.memberId).eq("occurrence_id", params.id)
        .in("status", ["booked", "pending_payment"]).order("created_at", { ascending: false }).limit(1).maybeSingle(),
      supabase.from("xendit_purchases").select("status")
        .eq("member_id", ctx.memberId).not("booking_id", "is", null)
        .order("created_at", { ascending: false }).limit(1).maybeSingle(),
    ]);
    const paid = (bk?.payments as { kind: string; status: string }[] | null ?? [])
      .some((p) => p.kind === "reservation_fee" && (p.status === "succeeded" || p.status === "partially_refunded"));
    const feeLabel = formatMoney(settings.reservationFeeCents, settings.currency);
    const when = `${fmtDayLong(data.occ.starts_at, ctx.timeZone)} at ${fmtTime(data.occ.starts_at, ctx.timeZone, ctx.timeFormat)}`;
    if (bk?.status === "booked" && bk.payment_source === "comp" && paid) {
      reserved = { state: "confirmed",
        line: `You're in. ${data.occ.name}, ${when}. Your ${feeLabel} reservation fee comes off your next purchase when you show up.` };
    } else if (bk?.status === "pending_payment" && pur?.status === "pending") {
      reserved = { state: "pending", line: "Finishing your payment…" };
    } else {
      reserved = { state: "lost", line: "Your spot wasn't held. Book again." };
    }
  }

  // Decision 35 amendment: waiver at the door. current_waiver is member-callable
  // and mirrors the service-only member_waiver_current.
  const { data: cw } = await supabase.rpc("current_waiver", { p_studio_id: ctx.studioId });
  const w = cw as { exists?: boolean; require_waiver?: boolean; signed?: boolean } | null;
  const waiverBlocked = !!(w?.require_waiver && w.exists && !w.signed);

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/book" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> All classes
      </Link>

      {reserved && (
        reserved.state === "pending"
          ? <ReservedPoll line={reserved.line} />
          : <div className="mb-4 rounded-2xl px-3.5 py-3 text-[13px] leading-[19px]"
                 style={reserved.state === "confirmed"
                   ? { background: "var(--accent-chip)", color: "var(--ink)" }
                   : { background: "var(--coral-tint)", color: "var(--ink)" }}>
              {reserved.line}
            </div>
      )}

      <ClassDetailBody occ={data.occ} type={data.type} booking={data.booking}
                       timeZone={ctx.timeZone} timeFormat={ctx.timeFormat} waitlistEnabled={settings.waitlistEnabled} guest={data.guest} freeFirst={data.freeFirst} pending={data.pending}
                       checkedIn={data.checkedIn} checkedInAt={data.checkedInAt} selfCheckinAvailable={data.selfCheckinAvailable}
                       opensBeforeMin={settings.checkinOpensBefore} closesAfterMin={settings.checkinClosesAfter}
                       unpaid={data.unpaid} group={data.group} covered={data.covered}
                       waiverBlocked={waiverBlocked}
                       seatKind={data.seatKind} cutoffMinutes={settings.cancellationCutoff} duplicateHold={data.duplicateHold} holdTime={data.holdTime}
                       deskPayAvailable={ctx.bootstrap?.desk_pay_available ?? true}
                       reservationFeeLabel={settings.reservationFeeCents > 0 ? formatMoney(settings.reservationFeeCents, settings.currency) : null} />
    </MemberShell>
  );
}
