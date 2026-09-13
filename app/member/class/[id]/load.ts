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
 */
export async function loadClassDetail(
  supabase: Supa,
  memberId: string,
  id: string,
): Promise<{ occ: DetailOccurrence; type: DetailType; booking: DetailBooking;
  guest: { enabled: boolean; canInvite: boolean } } | null> {
  const { data: occ } = await supabase
    .from("class_occurrences")
    .select("id, studio_id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, status, class_type_id, instructor_id, rooms(name), instructors!instructor_id(display_name, bio, avatar_url, certifications)")
    .eq("id", id)
    .maybeSingle();
  if (!occ) return null;

  const [{ data: type }, { data: booking }, { data: setting }, { count: activeGuests }] = await Promise.all([
    occ.class_type_id
      ? supabase.from("class_types").select("name, description, image_url, image_focus_x, image_focus_y").eq("id", occ.class_type_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("bookings")
      .select("id, status, waitlist_position")
      .eq("member_id", memberId)
      .eq("occurrence_id", id)
      .in("status", ["booked", "waitlisted"])
      .maybeSingle(),
    // Decision 26: does this studio run guest passes? A member cannot read
    // studio_settings directly (RLS), so the member-facing subset function
    // carries the flag.
    supabase.rpc("studio_member_settings", { p_studio_id: (occ as { studio_id: string }).studio_id }),
    // One guest at a time: does this member already have a live guest anywhere?
    supabase.from("guest_passes").select("id", { count: "exact", head: true })
      .eq("host_member_id", memberId).in("status", ["invited", "confirmed"]),
  ]);

  const enabled = (Array.isArray(setting) ? setting[0] : setting) as { guest_passes_enabled?: boolean } | null;
  const guestEnabled = enabled?.guest_passes_enabled ?? false;

  return {
    occ: occ as unknown as DetailOccurrence,
    type: (type ?? null) as DetailType,
    booking: (booking ?? null) as DetailBooking,
    guest: { enabled: guestEnabled, canInvite: guestEnabled && (activeGuests ?? 0) === 0 },
  };
}
