import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtClock } from "@/lib/clock";
import { fmtDayLong } from "@/lib/time";
import PrivateManage from "./manage";

export const dynamic = "force-dynamic";

/**
 * Decision 116: one private session, for the booker and any companion. The
 * occurrence is hidden; the member reads it through their own booking. The
 * booker can move it once and cancel it under the lead-time rule; a companion
 * sees it and is told to set up their account and sign the waiver.
 */
export default async function PrivatePage({ params, searchParams }: {
  params: { id: string }; searchParams: { paid?: string; booked?: string };
}) {
  const { ctx, supabase, settings, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const [{ data: occ }, { data: mine }, guard] = await Promise.all([
    supabase.from("class_occurrences")
      .select("id, name, starts_at, ends_at, status, committed_at, is_private, private_type_id, instructor_id, capacity, rooms(name), instructors!instructor_id(display_name)")
      .eq("id", params.id).maybeSingle(),
    supabase.from("bookings").select("id, status").eq("occurrence_id", params.id).eq("member_id", ctx.memberId).maybeSingle(),
    supabase.rpc("private_guard_booker", { p_occurrence_id: params.id }),
  ]);
  if (!occ || !occ.is_private || !mine) notFound();

  const isBooker = !guard.error;
  const coach = (occ.instructors as { display_name: string } | null)?.display_name?.split(" ")[0] ?? null;
  const room = (occ.rooms as { name: string } | null)?.name ?? null;
  const typeName = (occ.name as string).split(" · ")[0];
  const when = `${fmtDayLong(occ.starts_at, ctx.timeZone)}, ${fmtClock(occ.starts_at, ctx.timeZone, ctx.timeFormat)}`;
  const confirmed = occ.committed_at != null;
  const cancelled = occ.status === "cancelled" || mine.status === "cancelled" || mine.status === "late_cancelled";
  // the lead time arrives with the member (member_bootstrap); members cannot read studio_settings.
  const leadHours = settings.privateLeadHours;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Home
      </Link>
      <div className="m-card px-4 py-4">
        <p className="m-micro text-ink-2">Private session</p>
        <h1 className="m-title text-ink">{typeName}</h1>
        <p className="m-body mt-1 text-ink">{when}</p>
        <p className="m-sub text-ink-2">
          {[coach && `with ${coach}`, room, occ.capacity > 1 ? `${occ.capacity} people` : "Just you"].filter(Boolean).join(" · ")}
        </p>
        <p className="m-sub mt-3 font-semibold text-ink">
          {cancelled ? (mine.status === "late_cancelled" ? "Cancelled. The fee was kept." : "Cancelled.")
            : confirmed ? "You're booked in." : "Finishing your payment…"}
        </p>
      </div>

      {!cancelled && (
        <PrivateManage
          occurrenceId={occ.id as string} typeId={occ.private_type_id as string}
          coachId={(occ.instructor_id as string | null) ?? null}
          startsAt={occ.starts_at as string} timeZone={ctx.timeZone} timeFormat={ctx.timeFormat}
          leadHours={leadHours} isBooker={isBooker} confirmed={confirmed}
          polling={!confirmed && searchParams?.paid === "1"} />
      )}

      {!isBooker && !cancelled && (
        <p className="m-sub mt-4 text-ink-2">
          You&apos;ve been booked in by a friend. Check your email for the link to set up your
          account and sign the studio waiver before the session.
        </p>
      )}
    </MemberShell>
  );
}
