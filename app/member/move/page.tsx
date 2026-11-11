import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import MovePanel from "@/components/member/move-panel";
import { moveMyBooking } from "../actions";
import { orderRescueCards, type RescueCard } from "@/lib/flex-rescue";
import { fmtDayLong } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * Decision 95 — the flex-rescue move page. A member arrives here from a rescue
 * email's "Move me to this class" button (login-gated: /move?booking=X&target=Y).
 * The GET only renders; the move itself is a Server Action the client fires, so
 * an email link prefetch never mutates. Below the result sits the same list of
 * core classes, so a refusal still leads somewhere.
 */
export default async function MovePage({
  searchParams,
}: {
  searchParams: { booking?: string; target?: string };
}) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const bookingId = (searchParams.booking ?? "").trim();
  const targetId = (searchParams.target ?? "").trim() || null;

  // The member reads their OWN booking (RLS). From it, the source class to list
  // alternatives for. A booking that is not theirs or not live gives no list.
  let sourceOcc: string | null = null;
  let srcName = "your flex class";
  if (bookingId) {
    const { data: b } = await supabase
      .from("bookings")
      .select("occurrence_id, status, class_occurrences(name, class_type_id, class_types(name))")
      .eq("id", bookingId)
      .eq("member_id", ctx.memberId)
      .maybeSingle();
    if (b?.occurrence_id) {
      sourceOcc = b.occurrence_id as string;
      const occ = b.class_occurrences as { name?: string | null; class_types?: { name?: string | null } | null } | null;
      srcName = occ?.name || occ?.class_types?.name || srcName;
    }
  }

  let cards: RescueCard[] = [];
  if (sourceOcc) {
    const { data } = await supabase.rpc("core_classes_for_rescue", { p_occurrence_id: sourceOcc });
    cards = orderRescueCards(
      (data ?? []).map((r: Record<string, unknown>) => ({
        occurrence_id: r.occurrence_id as string,
        name: r.name as string,
        starts_at: r.starts_at as string,
        day_label: (r.day_label as string) || fmtDayLong(r.starts_at as string, ctx.timeZone),
        time_label: r.time_label as string,
        coach_first: (r.coach_first as string) || "",
        n_booked: Number(r.n_booked ?? 0),
        spots_left: Number(r.spots_left ?? 0),
      })),
    );
  }

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl} studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <MovePanel
        bookingId={bookingId}
        targetId={targetId}
        sourceName={srcName}
        cards={cards}
        move={moveMyBooking}
      />
    </MemberShell>
  );
}
