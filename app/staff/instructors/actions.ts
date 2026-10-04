"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type PhotoResult = { ok: boolean; message: string };

const BUCKET = "instructor-photos";

/** The object path inside our bucket, or null for an external/blank url. */
function pathInBucket(url: string | null): string | null {
  if (!url) return null;
  const marker = `/${BUCKET}/`;
  const i = url.indexOf(marker);
  return i === -1 ? null : url.slice(i + marker.length);
}

/**
 * Decision 60 — a manager uploads an instructor's photo. The browser has
 * already shrunk it to a small square JPEG; this stores it and writes the
 * PUBLIC url into instructors.avatar_url. The storage policy (manager of the
 * path's studio, or the instructor themselves) is the boundary — the server
 * client carries the user session, so a refused write raises here.
 */
export async function uploadInstructorPhoto(
  instructorId: string,
  fd: FormData,
): Promise<PhotoResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const file = fd.get("photo") as File | null;
  if (!file || file.size === 0) return { ok: false, message: "Choose a photo first." };
  // The browser shrinks to well under 200 KB; this is a sanity ceiling on what
  // actually arrives, not the 5 MB original limit (that is checked client-side).
  if (file.size > 2_000_000) return { ok: false, message: "That photo is too large after shrinking — try another." };
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { ok: false, message: "JPEG, PNG or WebP." };
  }

  const supabase = createClient();
  // Confirm the instructor is in this studio and read the url we may replace.
  const { data: inst } = await supabase.from("instructors")
    .select("id, avatar_url").eq("id", instructorId).eq("studio_id", ctx.studioId).maybeSingle();
  if (!inst) return { ok: false, message: "That instructor is not in this studio." };

  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  const path = `${ctx.studioId}/${instructorId}/${Date.now()}.${ext}`;
  const up = await supabase.storage.from(BUCKET).upload(path, file, { cacheControl: "3600", upsert: false });
  if (up.error) {
    return /row-level security|Unauthorized|denied/i.test(up.error.message)
      ? { ok: false, message: "You cannot set this instructor's photo." }
      : { ok: false, message: up.error.message };
  }

  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
  const { data, error } = await supabase.from("instructors")
    .update({ avatar_url: pub.publicUrl }).eq("id", instructorId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "The photo uploaded but the instructor could not be updated." };

  // Best-effort: drop the previous object if it was ours, so re-uploads do not
  // leave orphans. A failure here never blocks the new photo.
  const old = pathInBucket(inst.avatar_url);
  if (old && old !== path) await supabase.storage.from(BUCKET).remove([old]);

  revalidatePath(`/instructors/${instructorId}`);
  revalidatePath("/instructors");
  return { ok: true, message: "Photo updated." };
}

/** Decision 60 — clear the photo and delete the object (if it was ours). */
export async function removeInstructorPhoto(instructorId: string): Promise<PhotoResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };

  const supabase = createClient();
  const { data: inst } = await supabase.from("instructors")
    .select("id, avatar_url").eq("id", instructorId).eq("studio_id", ctx.studioId).maybeSingle();
  if (!inst) return { ok: false, message: "That instructor is not in this studio." };

  const { data, error } = await supabase.from("instructors")
    .update({ avatar_url: null }).eq("id", instructorId).select("id");
  if (error) return { ok: false, message: error.message };
  if (!data?.length) return { ok: false, message: "You cannot change this instructor's photo." };

  const old = pathInBucket(inst.avatar_url);
  if (old) await supabase.storage.from(BUCKET).remove([old]);

  revalidatePath(`/instructors/${instructorId}`);
  revalidatePath("/instructors");
  return { ok: true, message: "Photo removed." };
}
