"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { isDeleteConfirmed } from "@/lib/account-delete";

export type DeleteResult = { ok: true } | { error: string; contact?: boolean };

/**
 * Decision 69 — the member deletes their own account. The RPC acts on auth.uid()
 * only (no member id crosses the wire). On success the session is cleared and
 * the client lands on the public "deleted" page. A login that is also studio
 * staff/instructor is refused (PT403) with the studio's contact email.
 */
export async function deleteMyAccount(typed: string): Promise<DeleteResult> {
  const ctx = await getMemberContext();
  if (!ctx) return { error: "You are not signed in." };
  if (!isDeleteConfirmed(typed)) return { error: "Type DELETE to confirm." };

  const supabase = createClient();
  const { error } = await supabase.rpc("delete_my_account");
  if (error) {
    // PT403 = this login is studio staff / an instructor.
    if (error.code === "PT403") {
      return { error: "This login is part of a studio team, so it can't be deleted here. Please contact your studio.", contact: true };
    }
    return { error: error.message };
  }

  // The auth user is gone; clear the stale session cookie (best-effort).
  try { await supabase.auth.signOut(); } catch { /* user already gone */ }
  return { ok: true };
}
