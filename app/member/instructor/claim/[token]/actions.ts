"use server";

import { redirect } from "next/navigation";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import type { Database } from "@/lib/database.types";

export type ClaimState = { error: string } | null;

const SAYS: Record<string, string> = {
  invalid: "That link is not one we recognise.",
  used: "That link has already been used. Try signing in.",
  expired: "That link has expired — ask the studio for another.",
  password_too_short: "Eight characters or more, please.",
  already_claimed: "You already have an account here. Try signing in.",
};

/**
 * Claim, then sign in with the password just set.
 *
 * The claim runs on a cookie-less ANON client — the caller has no session and
 * must not borrow one. The sign-in that follows uses the cookie-writing client,
 * because that is the request that creates the session.
 */
export async function claimInstructor(
  _prev: ClaimState, form: FormData,
): Promise<ClaimState> {
  const token = String(form.get("token") ?? "");
  const password = String(form.get("password") ?? "");
  const fullName = String(form.get("full_name") ?? "").trim();

  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );

  // BEFORE the claim, not after. Claiming marks the invite accepted, so the
  // preview then answers 'used' with no email in it and the sign-in below
  // would have had nothing to use — landing somebody on a login screen thirty
  // seconds after they chose a password.
  const { data: pre } = await anon.rpc("instructor_invite_preview", { p_token: token });
  const email = (pre as { email?: string } | null)?.email ?? null;

  const { data, error } = await anon.rpc("claim_instructor_account", {
    p_token: token, p_password: password, p_full_name: fullName || undefined,
  });
  if (error) return { error: error.message };
  const r = (data ?? {}) as { state?: string; display_name?: string };
  if (r.state !== "ok") return { error: SAYS[r.state ?? "invalid"] ?? "That did not work." };

  // Straight in, rather than handing somebody a password and a login screen
  // thirty seconds after they chose it.
  const supabase = createClient();
  if (email) await supabase.auth.signInWithPassword({ email, password });
  redirect("/instructor");
}
