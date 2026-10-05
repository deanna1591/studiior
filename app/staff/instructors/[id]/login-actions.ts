"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type LoginState = { error: string } | { ok: string } | null;

/**
 * Decision 64 — the instructor's app login lives on a studio_staff row linked by
 * instructors.staff_id. An instructor row, a studio_staff row and an auth user
 * are three different things: invite_instructor() creates the staff row and a
 * one-time token, and the account only exists once they claim it.
 */
export async function inviteLogin(_prev: LoginState, form: FormData): Promise<LoginState> {
  const supabase = createClient();
  const id = String(form.get("instructor_id"));
  const { data, error } = await supabase.rpc("invite_instructor", {
    p_instructor_id: id,
    p_email: String(form.get("email") ?? "").trim(),
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { email?: string };
  revalidatePath(`/instructors/${id}`);
  return { ok: `Invite sent to ${r.email}. The link works once and lasts fourteen days.` };
}

/**
 * Remove the app login from this instructor. The teaching record (classes,
 * availability, pay, history) is untouched; the person can no longer sign in to
 * this studio, and can be invited again with any email.
 */
export async function removeLogin(_prev: LoginState, form: FormData): Promise<LoginState> {
  const supabase = createClient();
  const id = String(form.get("instructor_id"));
  const { data, error } = await supabase.rpc("remove_instructor_login", { p_instructor_id: id });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { email?: string };
  revalidatePath(`/instructors/${id}`);
  return { ok: `${r.email} can no longer sign in as this instructor. Invite them again below.` };
}
