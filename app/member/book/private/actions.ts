"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getMemberContext } from "@/lib/auth";
import { mergeSlots, slotReplaces, type Slot } from "@/lib/private-sessions";

/**
 * Decision 116: the free starts for one studio-local day (private_slots).
 * Decision 116(b): each start carries its coaches; an empty class only its own.
 */
export async function privateSlots(typeId: string, coachId: string | null, fromIso: string, toIso: string)
  : Promise<{ starts: string[]; replaces: string[]; slots: Slot[]; error?: string }> {
  const ctx = await getMemberContext();
  if (!ctx) return { starts: [], replaces: [], slots: [], error: "You are not signed in." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("private_slots", {
    p_studio_id: ctx.studioId, p_type_id: typeId, p_instructor_id: (coachId ?? null) as string,
    p_from: fromIso, p_to: toIso,
  });
  if (error) return { starts: [], replaces: [], slots: [], error: error.message };
  // mergeSlots normalises every start to toISOString(): groupGaps keys that way,
  // so a raw PostgREST "+00:00" string would never match.
  const slots = mergeSlots((data ?? []) as { starts_at: string; coach_ids: string[] | null; replaces_occurrence_id: string | null }[]);
  return {
    starts: slots.map((s) => s.start),
    replaces: slots.filter((s) => slotReplaces(s)).map((s) => s.start),
    slots,
  };
}

export async function cancelPrivate(occId: string): Promise<{ ok: boolean; onTime?: boolean; reason?: string; message?: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("private_cancel", { p_occurrence_id: occId });
  if (error) return { ok: false, message: error.message.replace(/^.*?:\s*/, "") };
  const r = data as { ok: boolean; on_time?: boolean; reason?: string };
  revalidatePath(`/private/${occId}`);
  return { ok: r.ok, onTime: r.on_time, reason: r.reason };
}

export async function movePrivate(occId: string, newStartIso: string): Promise<{ ok: boolean; reason?: string; message?: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("private_move", { p_occurrence_id: occId, p_new_start: newStartIso });
  if (error) return { ok: false, message: error.message.replace(/^.*?:\s*/, "") };
  const r = data as { ok: boolean; reason?: string };
  revalidatePath(`/private/${occId}`);
  return { ok: r.ok, reason: r.reason };
}
