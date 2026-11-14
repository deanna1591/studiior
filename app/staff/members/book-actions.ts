"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/database.types";
import { getStaffContext } from "@/lib/auth";
import { REASONS } from "@/lib/booking-reasons";
import { normalisePhone, PHONE_INVALID } from "@/lib/phone";
import { fullName } from "@/lib/full-name";

// Decision 100. Staff book a class for a member, and edit a member's phone.
// Every path is a thin wrapper over the SQL (staff_booking_options,
// staff_book_member, staff_set_member_phone); nothing re-implements the pick.

export type BookOption = {
  kind: string;
  label: string;
  membership_id?: string;
  price_cents?: number | null;
};
export type BookOptions = {
  member_first: string;
  class_name: string;
  starts_at: string;
  options: BookOption[];
  preselect: number;
} | null;

export async function bookingOptions(
  memberId: string, occurrenceId: string,
): Promise<BookOptions> {
  const supabase = createClient();
  const { data } = await supabase.rpc("staff_booking_options", {
    p_member_id: memberId, p_occurrence_id: occurrenceId,
  });
  return (data as unknown as BookOptions) ?? null;
}

export type BookResult = { ok: true; source: string } | { error: string };

export async function bookMemberAction(
  memberId: string, occurrenceId: string, source: BookOption, note: string | null,
): Promise<BookResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("staff_book_member", {
    p_member_id: memberId, p_occurrence_id: occurrenceId,
    p_source: source as unknown as Json, p_note: note ?? undefined,
  });
  if (error) {
    return { error: /PT403/.test(error.message)
      ? "Your role cannot do that. Front desk books with a plan, free first class or a drop-in; owners and managers can override or give a complimentary seat."
      : error.message };
  }
  const r = data as unknown as { ok: boolean; reason?: string; source?: string; member_first?: string };
  if (!r.ok) {
    const name = r.member_first ? `${r.member_first}: ` : "";
    const sentence = (r.reason && REASONS[r.reason]) || "That could not be booked.";
    return { error: `${name}${sentence}` };
  }
  revalidatePath(`/members/${memberId}`);
  revalidatePath(`/roster/${occurrenceId}`);
  return { ok: true, source: r.source ?? "a booking" };
}

export type MemberHit = { id: string; name: string; email: string };

export async function searchBookMembers(term: string): Promise<MemberHit[]> {
  const t = term.trim();
  if (t.length < 2) return [];
  const ctx = await getStaffContext();
  if (!ctx) return [];
  const supabase = createClient();
  const { data } = await supabase
    .from("members")
    .select("id, first_name, last_name, email")
    .eq("studio_id", ctx.studioId)
    .is("deleted_at", null)
    .or(`first_name.ilike.%${t}%,last_name.ilike.%${t}%,email.ilike.%${t}%`)
    .order("first_name")
    .limit(10);
  return (data ?? []).map((m) => ({
    id: m.id, name: fullName(m.first_name, m.last_name), email: m.email,
  }));
}

export type PickClass = {
  id: string; name: string; starts_at: string; spots_left: number; full: boolean;
};

export async function classPickerDays(): Promise<PickClass[]> {
  const ctx = await getStaffContext();
  if (!ctx) return [];
  const supabase = createClient();
  const now = new Date();
  const to = new Date(now.getTime() + 14 * 86400000);
  const { data } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, capacity, booked_count, class_type_id, class_types(name)")
    .eq("studio_id", ctx.studioId)
    .eq("status", "scheduled")
    .eq("hidden_from_members", false)
    .gt("starts_at", now.toISOString())
    .lt("starts_at", to.toISOString())
    .order("starts_at")
    .limit(200);
  return (data ?? []).map((o) => {
    const left = Math.max((o.capacity ?? 0) - (o.booked_count ?? 0), 0);
    return {
      id: o.id,
      name: (o.class_types as { name: string } | null)?.name ?? o.name ?? "a class",
      starts_at: o.starts_at as string,
      spots_left: left,
      full: left < 1,
    };
  });
}

export type PhoneTaken = { otherId: string; otherName: string; maskedEmail: string };

export async function setMemberPhoneAction(
  memberId: string, phoneRaw: string,
): Promise<{ ok: true; phone: string } | { error: string; taken?: PhoneTaken }> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();
  // Validate with the member sheet's own rule for the member-facing message.
  const { data: m } = await supabase
    .from("members").select("studio_id, studios(country)").eq("id", memberId).single();
  const country = (m?.studios as { country: string } | null)?.country ?? null;
  const e164 = normalisePhone(country, phoneRaw);
  if (e164 === null) return { error: PHONE_INVALID };
  const { data, error } = await supabase.rpc("staff_set_member_phone", {
    p_member_id: memberId, p_phone: e164,
  });
  if (error) {
    return { error: /PT403/.test(error.message)
      ? "Only the desk and up can edit contact details."
      : /PT422/.test(error.message) ? PHONE_INVALID
      : error.message };
  }
  const r = data as unknown as {
    ok: boolean; phone?: string; reason?: string;
    other_member_id?: string; other_name?: string; masked_email?: string;
  };
  // Decision 102: a phone belongs to one member per studio.
  if (!r.ok && r.reason === "phone_taken") {
    return {
      error: `This number is already on another account (${r.masked_email ?? ""}). Sign in to that account instead, or message the studio.`,
      taken: {
        otherId: r.other_member_id ?? "",
        otherName: r.other_name ?? "that member",
        maskedEmail: r.masked_email ?? "",
      },
    };
  }
  if (!r.ok) return { error: "That did not save." };
  revalidatePath(`/members/${memberId}`);
  return { ok: true, phone: r.phone ?? e164 };
}
