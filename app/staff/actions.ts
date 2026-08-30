"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { zonedToUtc } from "@/lib/time";

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
