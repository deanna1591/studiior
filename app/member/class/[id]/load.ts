import type { memberScreen } from "@/lib/member";
import type {
  DetailOccurrence, DetailType, DetailBooking,
} from "@/components/member/class-detail-body";

type Supa = Awaited<ReturnType<typeof memberScreen>>["supabase"];

/**
 * The one query behind the class-detail screen, shared by the full page and the
 * intercepting sheet so both read exactly the same rows through the same
 * RLS-bound client. Returns null when the class is not found OR not visible to
 * this member — the two are deliberately the same answer, so a 404 cannot
 * confirm a class exists at a studio the member has nothing to do with.
 *
 * Serial depth: only `type` needs the occurrence (its class_type_id); the
 * booking and guest-count reads need only the id and the member, so they run in
 * PARALLEL with the occurrence. When the caller passes classTypeId — the list
 * card already knows it — even `type` joins that first wave, so a tap from the
 * day list resolves in ONE round trip rather than occurrence-then-batch. A deep
 * link or refresh has no hint and falls back to occurrence, then type.
 */
export async function loadClassDetail(
  supabase: Supa,
  memberId: string,
  id: string,
  guestPassesEnabled: boolean,
  classTypeId?: string | null,
): Promise<{ occ: DetailOccurrence; type: DetailType; booking: DetailBooking;
  guest: { enabled: boolean; canInvite: boolean } } | null> {

  const occQuery = supabase
    .from("class_occurrences")
    .select("id, studio_id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, status, class_type_id, instructor_id, rooms(name), instructors!instructor_id(display_name, bio, avatar_url, certifications)")
    .eq("id", id).maybeSingle();
  const typeQuery = (ctid: string) => supabase.from("class_types")
    .select("name, description, image_url, image_focus_x, image_focus_y").eq("id", ctid).maybeSingle();
  const bookingQuery = supabase.from("bookings")
    .select("id, status, waitlist_position")
    .eq("member_id", memberId).eq("occurrence_id", id)
    .in("status", ["booked", "waitlisted"]).maybeSingle();
  const guestQuery = guestPassesEnabled
    ? supabase.from("guest_passes").select("id", { count: "exact", head: true })
        .eq("host_member_id", memberId).in("status", ["invited", "confirmed"])
    : Promise.resolve({ count: 0 });

  const finish = (occ: Record<string, unknown> | null, type: unknown, booking: unknown, activeGuests: number | null) => {
    if (!occ) return null;
    return {
      occ: occ as unknown as DetailOccurrence,
      type: (type ?? null) as DetailType,
      booking: (booking ?? null) as DetailBooking,
      guest: { enabled: guestPassesEnabled, canInvite: guestPassesEnabled && (activeGuests ?? 0) === 0 },
    };
  };

  if (classTypeId) {
    // One wave: nothing waits on the occurrence.
    const [{ data: occ }, { data: type }, { data: booking }, { count: activeGuests }] =
      await Promise.all([occQuery, typeQuery(classTypeId), bookingQuery, guestQuery]);
    return finish(occ, type, booking, activeGuests);
  }

  // No hint (deep link / refresh): occurrence, booking and guest in parallel;
  // then type, the one read that needs the occurrence's class_type_id.
  const [{ data: occ }, { data: booking }, { count: activeGuests }] =
    await Promise.all([occQuery, bookingQuery, guestQuery]);
  if (!occ) return null;
  const { data: type } = occ.class_type_id ? await typeQuery(occ.class_type_id) : { data: null };
  return finish(occ as Record<string, unknown>, type, booking, activeGuests);
}
