"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type ChallengeFormState = { error: string } | null;
export type CoverState = { ok: boolean; message: string } | null;

/**
 * Upload a challenge cover — same bucket and the same policy as the class-type
 * and login photos (studio id is the first path segment, so a session cannot
 * write into another studio's folder), and the URL goes on challenges, which
 * challenges_manager_write guards. Resets the focal point to centre, because a
 * new picture has a new subject.
 */
async function storeCover(challengeId: string, studioId: string, file: File): Promise<CoverState> {
  if (file.size > 2_000_000) {
    return { ok: false, message: "That photo is over 2 MB. Exporting it around 1600px wide gets under." };
  }
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { ok: false, message: "JPEG, PNG or WebP." };
  }
  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${studioId}/challenge-${challengeId}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from("studio-branding")
    .upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? { ok: false, message: "Only owners and managers can change the cover." }
      : { ok: false, message: error.message };
  }
  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data: rows, error: upErr } = await supabase.from("challenges")
    .update({ cover_image_url: pub.publicUrl, cover_image_focus_x: 50, cover_image_focus_y: 50 })
    .eq("id", challengeId).select("id");
  if (upErr) return { ok: false, message: upErr.message };
  if (!rows?.length) return { ok: false, message: "The photo uploaded but the challenge could not be updated." };
  return { ok: true, message: "Cover updated. Set the focal point below so it crops well on a phone." };
}

export async function uploadChallengeCover(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const id = String(fd.get("challenge_id") ?? "");
  const file = fd.get("cover") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  const res = await storeCover(id, ctx.studioId, file);
  if (res?.ok) { revalidatePath(`/challenges/${id}`); revalidatePath("/challenges"); }
  return res;
}

export async function saveChallengeCoverFocus(_prev: CoverState, fd: FormData): Promise<CoverState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const id = String(fd.get("challenge_id") ?? "");
  const clamp = (k: string) => Math.min(100, Math.max(0, Math.round(Number(fd.get(k) ?? 50))));
  const supabase = createClient();
  const { data, error } = await supabase.from("challenges")
    .update({ cover_image_focus_x: clamp("focus_x"), cover_image_focus_y: clamp("focus_y") })
    .eq("id", id).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Nothing was saved. Owners and managers only." };
  revalidatePath(`/challenges/${id}`); revalidatePath("/challenges");
  return { ok: true, message: "Saved." };
}

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

  // Optional cover chosen on the create form — the challenge exists now, so it
  // has an id to store the file under. A bad image does not fail the create;
  // the studio lands on the challenge and can try the cover again there.
  const cover = fd.get("cover") as File | null;
  if (cover && cover.size > 0) await storeCover(data as string, ctx.studioId, cover);

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
