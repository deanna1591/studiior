"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { privateReasonSentence } from "@/lib/private-sessions";

export type StaffPrivateOptions = {
  enabled: boolean; timeZone: string; currency: string;
  types: { id: string; name: string; people: number; price_cents: number; duration_min: number }[];
  coaches: { id: string; name: string }[];
};

/** Decision 116: what the staff "Book a private" sheet offers. */
export async function staffPrivateOptions(): Promise<StaffPrivateOptions | null> {
  const ctx = await getStaffContext();
  if (!ctx) return null;
  const supabase = createClient();
  const [{ data: st }, { data: types }, { data: coaches }, { data: studio }] = await Promise.all([
    supabase.from("studio_settings").select("private_sessions_enabled").eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("private_session_types").select("id, name, people, price_cents, duration_min")
      .eq("studio_id", ctx.studioId).eq("active", true).order("sort").order("people"),
    supabase.from("instructors").select("id, display_name").eq("studio_id", ctx.studioId)
      .eq("status", "active").eq("teaches_privates", true).order("display_name"),
    supabase.from("studios").select("timezone, currency").eq("id", ctx.studioId).maybeSingle(),
  ]);
  return {
    enabled: st?.private_sessions_enabled ?? false,
    timeZone: studio?.timezone ?? "UTC", currency: studio?.currency ?? "PHP",
    types: (types ?? []) as StaffPrivateOptions["types"],
    coaches: (coaches ?? []).map((c) => ({ id: c.id as string, name: c.display_name as string })),
  };
}

export async function staffPrivateSlots(typeId: string, coachId: string | null, fromIso: string, toIso: string) {
  const ctx = await getStaffContext();
  if (!ctx) return { starts: [] as string[] };
  const supabase = createClient();
  const { data } = await supabase.rpc("private_slots", {
    p_studio_id: ctx.studioId, p_type_id: typeId, p_instructor_id: (coachId ?? null) as string,
    p_from: fromIso, p_to: toIso,
  });
  return { starts: ((data ?? []) as { starts_at: string }[]).map((r) => r.starts_at) };
}

export async function staffBookPrivate(input: {
  memberId: string; typeId: string; coachId: string | null; startsAt: string;
  companions: { name: string; email: string }[]; method: string; reference: string;
}): Promise<{ ok: boolean; message: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("private_book_desk", {
    p_member_id: input.memberId, p_type_id: input.typeId, p_instructor_id: (input.coachId ?? null) as string,
    p_starts_at: input.startsAt, p_companions: input.companions, p_method: input.method,
    p_reference: input.reference || undefined,
  });
  if (error) return { ok: false, message: error.message.replace(/^.*?:\s*/, "") };
  const r = data as { ok: boolean; reason?: string };
  if (!r.ok) return { ok: false, message: privateReasonSentence(r.reason) };
  revalidatePath(`/members/${input.memberId}`);
  return { ok: true, message: "Booked and confirmed. The client and the coach have been emailed." };
}
