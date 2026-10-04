"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type PhotoResult = { ok: boolean; message: string };

const BUCKET = "instructor-photos";

function pathInBucket(url: string | null): string | null {
  if (!url) return null;
  const marker = `/${BUCKET}/`;
  const i = url.indexOf(marker);
  return i === -1 ? null : url.slice(i + marker.length);
}

/** Resolve the signed-in instructor without redirecting (this is an action). */
async function me(supabase: ReturnType<typeof createClient>) {
  const { data } = await supabase.rpc("my_instructor");
  const ctx = data as { instructor_id?: string; studio_id?: string; avatar_url?: string | null } | null;
  return ctx?.instructor_id && ctx?.studio_id
    ? { instructorId: ctx.instructor_id, studioId: ctx.studio_id, avatarUrl: ctx.avatar_url ?? null }
    : null;
}

/**
 * Decision 60 — an instructor uploads their OWN photo from the portal Me page.
 * The storage self-branch (path's instructor_id joins to the caller's own
 * studio_staff) and the instructors_self_update RLS both allow only their own
 * row and their own folder, so this needs no id argument and answers for nobody
 * else. The browser has already shrunk the file.
 */
export async function uploadMyPhoto(fd: FormData): Promise<PhotoResult> {
  const supabase = createClient();
  const who = await me(supabase);
  if (!who) return { ok: false, message: "Not signed in." };

  const file = fd.get("photo") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  if (file.size > 2_000_000) return { ok: false, message: "That photo is too large after shrinking — try another." };
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { ok: false, message: "JPEG, PNG or WebP." };
  }

  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  const path = `${who.studioId}/${who.instructorId}/${Date.now()}.${ext}`;
  const up = await supabase.storage.from(BUCKET).upload(path, file, { cacheControl: "3600", upsert: false });
  if (up.error) {
    return /row-level security|Unauthorized|denied/i.test(up.error.message)
      ? { ok: false, message: "That photo could not be saved." }
      : { ok: false, message: up.error.message };
  }

  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
  const { data, error } = await supabase.from("instructors")
    .update({ avatar_url: pub.publicUrl }).eq("id", who.instructorId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "The photo uploaded but your profile could not be updated." };

  const old = pathInBucket(who.avatarUrl);
  if (old && old !== path) await supabase.storage.from(BUCKET).remove([old]);

  revalidatePath("/instructor/me");
  revalidatePath("/instructor");
  return { ok: true, message: "Photo updated." };
}

/** Decision 60 — the instructor removes their own photo. */
export async function removeMyPhoto(): Promise<PhotoResult> {
  const supabase = createClient();
  const who = await me(supabase);
  if (!who) return { ok: false, message: "Not signed in." };

  const { data, error } = await supabase.from("instructors")
    .update({ avatar_url: null }).eq("id", who.instructorId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "Your photo could not be changed." };

  const old = pathInBucket(who.avatarUrl);
  if (old) await supabase.storage.from(BUCKET).remove([old]);

  revalidatePath("/instructor/me");
  revalidatePath("/instructor");
  return { ok: true, message: "Photo removed." };
}
