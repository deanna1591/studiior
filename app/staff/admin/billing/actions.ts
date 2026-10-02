"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type ExtendState = { ok: boolean; message: string } | null;
export type CompState = { ok: boolean; message: string } | null;

/**
 * These are OPERATOR actions, reached from /admin/billing. The real boundary is
 * in the SQL (extend_trial / set_studio_complimentary / clear_studio_complimentary
 * all check is_platform_admin). They must NOT call getStaffContext(): a platform
 * operator may be staff of no studio, and that check would refuse the very person
 * these are for — the same bug the /admin/billing page had.
 */

export async function extendTrial(_prev: ExtendState, fd: FormData): Promise<ExtendState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("extend_trial", {
    p_studio_id: String(fd.get("studio_id") ?? ""),
    p_days: Number(fd.get("days") ?? 14),
  });
  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "Operators only." }
      : { ok: false, message: error.message };
  }
  revalidatePath("/admin/billing");
  return { ok: true, message: "Extended." };
}

/** Decision 53 — mark a studio complimentary (note required). Platform admin
 *  only, enforced in set_studio_complimentary(). */
export async function setComplimentary(_prev: CompState, fd: FormData): Promise<CompState> {
  const note = String(fd.get("note") ?? "").trim();
  if (!note) return { ok: false, message: "Add a note — why is this studio complimentary?" };
  const supabase = createClient();
  const { error } = await supabase.rpc("set_studio_complimentary", {
    p_studio_id: String(fd.get("studio_id") ?? ""),
    p_note: note,
  });
  if (error) {
    return /PT403/.test(error.message) ? { ok: false, message: "Operators only." }
      : /PT400/.test(error.message) ? { ok: false, message: "A note is required." }
      : { ok: false, message: error.message };
  }
  revalidatePath("/admin/billing");
  return { ok: true, message: "Marked complimentary." };
}

/** Decision 53 — stop complimentary: starts a fresh 14-day trial. */
export async function clearComplimentary(_prev: CompState, fd: FormData): Promise<CompState> {
  const supabase = createClient();
  const { error } = await supabase.rpc("clear_studio_complimentary", {
    p_studio_id: String(fd.get("studio_id") ?? ""),
  });
  if (error) {
    return /PT403/.test(error.message) ? { ok: false, message: "Operators only." }
      : /PT409/.test(error.message) ? { ok: false, message: "That studio is not complimentary." }
      : { ok: false, message: error.message };
  }
  revalidatePath("/admin/billing");
  return { ok: true, message: "Stopped — a fresh 14-day trial has started." };
}
