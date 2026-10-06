"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type JoinState = { error: string } | null;

const STATE_MESSAGE: Record<string, string> = {
  invalid: "This invite link is not valid. Ask for a new one.",
  used: "This invite has already been used. Sign in instead.",
  expired: "This invite has expired. Ask for a fresh link.",
  password_too_short: "Use a password of at least 8 characters.",
  already_claimed: "This account already exists. Sign in instead.",
};

/** Decision 70 — claim a manager/front-desk invite, then sign in on the staff
 *  host and land on the dashboard. Reuses the generalised instructor claim RPC. */
export async function joinTeam(_prev: JoinState, fd: FormData): Promise<JoinState> {
  const token = String(fd.get("token") ?? "");
  const email = String(fd.get("email") ?? "");
  const password = String(fd.get("password") ?? "");
  const fullName = String(fd.get("full_name") ?? "").trim();

  const supabase = createClient();
  const { data, error } = await supabase.rpc("claim_instructor_account", {
    p_token: token, p_password: password, p_full_name: fullName || undefined,
  });
  if (error) return { error: error.message };

  const r = data as unknown as { state: string } | null;
  if (!r) return { error: "No response from the database." };
  if (r.state !== "ok") return { error: STATE_MESSAGE[r.state] ?? r.state };

  const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
  if (signInError) {
    return { error: `Your account was created, but sign-in failed: ${signInError.message}` };
  }
  redirect("/");
}
