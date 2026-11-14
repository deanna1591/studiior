"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { fullName } from "@/lib/full-name";

export type DangerState = { ok: boolean; message: string; href?: string } | null;

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers can do that."
  : /PT404/.test(m) ? "That member is no longer there."
  : /PT40[0-9]/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

/** Same-studio members to merge into (the one to KEEP). Excludes the member
 *  being merged and anyone already deleted. Manager-up by RLS on members. */
export async function searchMergeTargets(
  studioId: string, excludeId: string, q: string,
): Promise<{ id: string; name: string; email: string }[]> {
  const term = q.trim();
  if (term.length < 2) return [];
  const supabase = createClient();
  const { data } = await supabase
    .from("members")
    .select("id, first_name, last_name, email")
    .eq("studio_id", studioId)
    .is("deleted_at", null)
    .neq("id", excludeId)
    .or(`first_name.ilike.%${term}%,last_name.ilike.%${term}%,email.ilike.%${term}%`)
    .order("first_name")
    .limit(8);
  return (data ?? []).map((m) => ({
    id: m.id, name: fullName(m.first_name, m.last_name), email: m.email,
  }));
}

/** The confirm-screen counts: what moves from the duplicate onto the kept member. */
export async function mergePreview(keepId: string, removeId: string) {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("merge_preview", {
    p_keep: keepId, p_remove: removeId,
  });
  if (error) return { ok: false, reason: say(error.message) } as const;
  return data as unknown as {
    ok: boolean; reason: string | null;
    keep_name: string; keep_email: string; remove_name: string; remove_email: string;
    counts: { bookings: number; payments: number; credits: number; passes: number; check_ins: number; messages: number; memberships_moving: number };
    two_active: boolean;
  };
}

/** Merge the duplicate (removeId) into the member to keep (keepId). */
export async function mergeMembers(_prev: DangerState, fd: FormData): Promise<DangerState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const keepId = String(fd.get("keep_id") ?? "");
  const removeId = String(fd.get("remove_id") ?? "");
  const typed = String(fd.get("confirm_name") ?? "").trim();
  const keepName = String(fd.get("keep_name") ?? "").trim();
  if (!keepId || !removeId) return { ok: false, message: "Pick a member to keep." };
  if (typed.toLowerCase() !== keepName.toLowerCase()) {
    return { ok: false, message: `Type ${keepName} to confirm the merge.` };
  }
  const supabase = createClient();
  const { error } = await supabase.rpc("merge_members", { p_keep: keepId, p_remove: removeId });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/members");
  revalidatePath(`/members/${keepId}`);
  return { ok: true, message: "Merged.", href: `/members/${keepId}` };
}

/** Delete a member (staff). Scrubs, keeps history, removes a sole-studio login. */
export async function deleteMember(_prev: DangerState, fd: FormData): Promise<DangerState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const memberId = String(fd.get("member_id") ?? "");
  const typed = String(fd.get("confirm_name") ?? "").trim();
  const firstName = String(fd.get("first_name") ?? "").trim();
  if (typed.toLowerCase() !== firstName.toLowerCase()) {
    return { ok: false, message: `Type ${firstName} to confirm.` };
  }
  const supabase = createClient();
  const { error } = await supabase.rpc("delete_member", { p_member_id: memberId });
  if (error) return { ok: false, message: say(error.message) };
  revalidatePath("/members");
  return { ok: true, message: "Deleted.", href: "/members" };
}
