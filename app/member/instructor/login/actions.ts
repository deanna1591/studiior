"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type SignInState = { error: string } | null;

/**
 * Sign in and land on THEIR OWN SCREEN.
 *
 * An instructor signing in through the staff app used to arrive at the
 * dashboard — a wall of revenue, churn and occupancy about a business that is
 * not theirs, most of which the database then refuses to answer. This checks
 * they are an instructor here and sends them to the portal.
 */
export async function instructorSignIn(
  _prev: SignInState, form: FormData,
): Promise<SignInState> {
  const supabase = createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: String(form.get("email") ?? "").trim(),
    password: String(form.get("password") ?? ""),
  });
  if (error) return { error: "That email and password do not match." };

  const { data } = await supabase.rpc("my_instructor");
  if (!data) {
    await supabase.auth.signOut();
    return {
      error: "That account is not an instructor at this studio. " +
             "If you are staff, sign in on the main site instead.",
    };
  }
  redirect("/instructor");
}
