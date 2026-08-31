"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { zonedToUtc } from "@/lib/time";
import { memberOrigin } from "@/lib/tenant";

export async function signIn(_prev: string | null, formData: FormData) {
  const supabase = createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: String(formData.get("email") ?? ""),
    password: String(formData.get("password") ?? ""),
  });
  if (error) return error.message;
  redirect("/");
}

export async function signOut() {
  const supabase = createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function createClassOccurrence(_prev: string | null, formData: FormData) {
  const ctx = await getStaffContext();
  if (!ctx) return "Not signed in.";

  const supabase = createClient();

  const classTypeId = String(formData.get("class_type_id") ?? "");
  const date = String(formData.get("date") ?? "");
  const time = String(formData.get("time") ?? "");
  const capacity = Number(formData.get("capacity") ?? 0);
  const instructorId = String(formData.get("instructor_id") ?? "") || null;
  const roomId = String(formData.get("room_id") ?? "") || null;

  if (!classTypeId || !date || !time || !capacity) return "Every field except room is required.";

  const { data: classType } = await supabase
    .from("class_types")
    .select("name, duration_minutes")
    .eq("id", classTypeId)
    .maybeSingle();
  if (!classType) return "That class type no longer exists.";

  const { data: location } = await supabase
    .from("locations")
    .select("id")
    .eq("studio_id", ctx.studioId)
    .eq("is_primary", true)
    .maybeSingle();
  if (!location) return "This studio has no primary location.";

  // The form collects studio-local wall-clock time. Convert at the instant it
  // refers to, so a 07:00 class is 07:00 on either side of a DST change.
  const startsAt = zonedToUtc(date, time, ctx.timeZone);
  const endsAt = new Date(startsAt.getTime() + classType.duration_minutes * 60_000);

  // No role check here on purpose. occ_manager_write decides whether this
  // insert is allowed; a front desk user gets a policy refusal, which is the
  // permission actually being enforced.
  const { error } = await supabase.from("class_occurrences").insert({
    studio_id: ctx.studioId,
    location_id: location.id,
    class_type_id: classTypeId,
    name: classType.name,
    instructor_id: instructorId,
    room_id: roomId,
    capacity,
    starts_at: startsAt.toISOString(),
    ends_at: endsAt.toISOString(),
  });

  if (error) {
    return error.code === "42501" || /row-level security/i.test(error.message)
      ? "Your role cannot create classes. Managers and owners only."
      : error.message;
  }

  revalidatePath("/");
  redirect("/");
}

export async function checkIn(_prev: string | null, formData: FormData) {
  const ctx = await getStaffContext();
  if (!ctx) return "Not signed in.";

  const supabase = createClient();
  const bookingId = String(formData.get("booking_id") ?? "");
  const occurrenceId = String(formData.get("occurrence_id") ?? "");
  const memberId = String(formData.get("member_id") ?? "");

  const { error } = await supabase.from("check_ins").insert({
    studio_id: ctx.studioId,
    booking_id: bookingId,
    member_id: memberId,
    occurrence_id: occurrenceId,
    method: "staff",
    checked_in_by: ctx.userId,
  });

  if (error) {
    if (error.code === "23505") return "Already checked in.";
    // PT422 is raised by the §8 check-in window trigger (migration 007). The
    // rule lives in SQL; this only puts its message on screen.
    if (error.code === "PT422") return error.message;
    return /row-level security/i.test(error.message)
      ? "Your role cannot check members in."
      : error.message;
  }

  revalidatePath(`/roster/${occurrenceId}`);
  return null;
}


export type CodeState = { ok: boolean; message: string } | null;

/**
 * Check a member in from the rotating code on their phone.
 *
 * Permissions §8 note 13. resolve_checkin_code() accepts the current or the
 * previous 30-second bucket, so a code that rotates while the desk is typing
 * still works — and it is desk-up only, so a member cannot resolve anybody's
 * code including their own.
 */
export async function checkInByCode(_prev: CodeState, fd: FormData): Promise<CodeState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const code = String(fd.get("code") ?? "").trim();
  const occurrenceId = String(fd.get("occurrence_id") ?? "");
  if (!code) return { ok: false, message: "Type the code from their phone." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("resolve_checkin_code", { p_code: code });
  if (error) return { ok: false, message: error.message };

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) {
    return {
      ok: false,
      message: "That code did not match anyone. Codes change every 30 seconds — ask them to read out the current one.",
    };
  }

  const { data: booking } = await supabase
    .from("bookings")
    .select("id, status")
    .eq("occurrence_id", occurrenceId)
    .eq("member_id", row.member_id)
    .in("status", ["booked", "attended"])
    .maybeSingle();

  if (!booking) {
    return {
      ok: false,
      message: `${row.first_name} ${row.last_name} is not booked into this class. Book them in first, or check the class.`,
    };
  }

  const { error: ciError } = await supabase.from("check_ins").insert({
    studio_id: ctx.studioId,
    booking_id: booking.id,
    member_id: row.member_id,
    occurrence_id: occurrenceId,
    method: "qr",
    checked_in_by: ctx.userId,
  });
  if (ciError) {
    if (ciError.code === "23505") {
      return { ok: true, message: `${row.first_name} is already checked in.` };
    }
    // PT422 is the §8 window trigger. The rule lives in SQL; this shows it.
    if (ciError.code === "PT422") return { ok: false, message: ciError.message };
    return { ok: false, message: ciError.message };
  }

  await supabase.from("bookings").update({ status: "attended" }).eq("id", booking.id);
  revalidatePath(`/roster/${occurrenceId}`);
  return { ok: true, message: `${row.first_name} ${row.last_name} checked in.` };
}

export type InviteState = { ok: boolean; message: string; link?: string } | null;

/**
 * Mint an app invite for one member.
 *
 * The raw token comes back exactly once and is not stored — only its hash is
 * (migration 027). Nothing sends it: the link is handed to whoever asked for
 * it, the same as the studio invite in migration 012, because there is still
 * no transport and inventing one here would be the third place that pretends.
 */
export async function inviteMemberToApp(_prev: InviteState, fd: FormData): Promise<InviteState> {
  const memberId = String(fd.get("member_id") ?? "");
  const supabase = createClient();

  const { data, error } = await supabase.rpc("create_member_invite", {
    p_member_id: memberId,
    p_days: 14,
  });
  if (error) {
    if (error.code === "PT403") return { ok: false, message: "Owners, managers and front desk can invite members." };
    if (error.code === "PT409") return { ok: false, message: error.message };
    return { ok: false, message: error.message };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return { ok: false, message: "No invite was created." };

  revalidatePath(`/members/${memberId}`);
  revalidatePath("/members");

  const ctx = await getStaffContext();
  const { data: studio } = await supabase
    .from("studios").select("slug").eq("id", ctx?.studioId ?? "").maybeSingle();

  return {
    ok: true,
    message: `Send this link to ${row.email}. It works once and expires in 14 days.`,
    link: studio?.slug ? `${memberOrigin(studio.slug)}/claim/${row.token}` : undefined,
  };
}
