"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type InviteState = { error: string } | { ok: string } | null;

/**
 * Invite an instructor to sign in.
 *
 * An instructor row, a studio_staff row and an auth user are three different
 * things: invite_instructor() creates the staff row and the token, and the
 * account only exists once they claim it. Nothing here shortcuts that.
 */
export async function sendInstructorInvite(
  _prev: InviteState, form: FormData,
): Promise<InviteState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("invite_instructor", {
    p_instructor_id: String(form.get("instructor_id")),
    p_email: String(form.get("email") ?? "").trim(),
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { email?: string };
  revalidatePath("/instructors/access");
  return { ok: `Sent to ${r.email}. The link works once and lasts fourteen days.` };
}
