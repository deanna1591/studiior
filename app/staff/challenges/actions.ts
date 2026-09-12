"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type ChallengeFormState = { error: string } | null;

/**
 * Create a challenge — members only. The date rules live in create_challenge()
 * (and the table's CHECKs), so a bad range comes back as a sentence rather than
 * a raw constraint error, and the client cannot post an instructor challenge:
 * audience is fixed to member in the function.
 */
export async function createChallenge(
  _prev: ChallengeFormState, fd: FormData,
): Promise<ChallengeFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();

  const title = String(fd.get("title") ?? "").trim();
  if (!title) return { error: "A challenge needs a title." };
  const type = String(fd.get("type") ?? "class_count");
  const goal = Number(fd.get("goal_value"));
  if (!Number.isFinite(goal) || goal <= 0) return { error: "The goal must be a number above zero." };

  const starts = String(fd.get("starts_on") ?? "");
  const ends = String(fd.get("ends_on") ?? "");
  const deadline = String(fd.get("join_deadline") ?? "");
  if (!starts || !ends || !deadline) return { error: "Set the start, end and join deadline." };

  // Only kept for a class-type challenge; discarded otherwise so the form's
  // hidden fields cannot post a filter the type does not use.
  const typeIds = type === "class_type_count"
    ? fd.getAll("class_type_ids").map(String).filter(Boolean)
    : [];

  const { data, error } = await supabase.rpc("create_challenge", {
    p_studio_id: ctx.studioId,
    p_title: title,
    p_type: type as "class_count" | "streak" | "class_type_count",
    p_goal_value: Math.floor(goal),
    p_starts_on: starts,
    p_ends_on: ends,
    p_join_deadline: deadline,
    p_class_type_ids: typeIds,
    p_reward: String(fd.get("reward") ?? "").trim() || undefined,
    p_leaderboard: fd.get("leaderboard") === "on",
    p_description: String(fd.get("description") ?? "").trim() || undefined,
    p_template_id: String(fd.get("template_id") ?? "") || undefined,
  });
  if (error) return { error: error.message };

  revalidatePath("/challenges");
  redirect(`/challenges/${data as string}`);
}

/** Publish a draft — draft → scheduled (or active if it has already begun). */
export async function publishChallenge(fd: FormData): Promise<void> {
  const ctx = await getStaffContext();
  if (!ctx) return;
  const supabase = createClient();
  const id = String(fd.get("challenge_id") ?? "");
  const { error } = await supabase.rpc("publish_challenge", { p_challenge_id: id });
  if (error) throw new Error(error.message);
  revalidatePath("/challenges");
  revalidatePath(`/challenges/${id}`);
}
