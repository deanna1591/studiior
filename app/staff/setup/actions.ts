"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type SetupState = { error: string } | null;

const num = (fd: FormData, key: string, fallback: number) => {
  const n = Number(String(fd.get(key) ?? "").trim());
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
};
const text = (fd: FormData, key: string) => String(fd.get(key) ?? "").trim();
const nullable = (fd: FormData, key: string) => text(fd, key) || null;

/**
 * A refused write returns zero rows rather than an error (CLAUDE.md), so every
 * update here checks what it changed. Without it a front desk user editing a
 * room would be told it saved.
 */
function refusal(kind: string): SetupState {
  return { error: `Your role cannot change ${kind}. Owners and managers only.` };
}
function insertRefused(error: { code?: string; message: string }) {
  return /row-level security/i.test(error.message) || error.code === "42501";
}

export async function saveRoom(_prev: SetupState, fd: FormData): Promise<SetupState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();

  const id = text(fd, "id");
  const name = text(fd, "name");
  if (!name) return { error: "A room needs a name." };
  const capacity = num(fd, "capacity", 0);
  if (capacity < 1) return { error: "Capacity must be at least 1." };
  const row = { name, capacity, color: nullable(fd, "color"), status: text(fd, "status") || "active" };

  if (id) {
    const { data, error } = await supabase.from("rooms").update(row).eq("id", id).select("id");
    if (error) return { error: error.message };
    if (!data?.length) return refusal("rooms");
  } else {
    // rooms.location_id is NOT NULL; a studio has exactly one location in V1
    // (Decision 8) and provisioning creates it.
    const { data: loc } = await supabase.from("locations").select("id")
      .eq("studio_id", ctx.studioId).eq("is_primary", true).maybeSingle();
    if (!loc) return { error: "This studio has no location to put a room in." };
    const { error } = await supabase.from("rooms")
      .insert({ ...row, studio_id: ctx.studioId, location_id: loc.id });
    if (error) return insertRefused(error) ? refusal("rooms") : { error: error.message };
  }
  revalidatePath("/rooms"); revalidatePath("/");
  redirect("/rooms");
}

/**
 * A photograph of a class.
 *
 * Into studio-branding under `<studio id>/class-types/`, which migration 035
 * opened to managers — migration 029's write policy is owner-only, so a manager
 * uploading here would have been refused by storage while the screen said
 * nothing. Permissions §4 gives class types to Owner AND Manager, so the policy
 * had to move rather than the screen.
 *
 * Public, unlike a member's photograph: this is studio marketing.
 */
export async function uploadClassTypeImage(_prev: SetupState, fd: FormData): Promise<SetupState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const id = text(fd, "id");
  if (!id) return { error: "Save the class type before adding a photo." };

  const file = fd.get("image") as File | null;
  if (!file || file.size === 0) return { error: "Choose a photo first." };
  if (file.size > 2_000_000) {
    return { error: "That photo is over 2 MB, which is the most this can store. About 1600px wide is usually well inside." };
  }
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    return { error: "JPEG, PNG or WebP." };
  }

  const supabase = createClient();
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "jpg";
  const path = `${ctx.studioId}/class-types/${id}-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from("studio-branding").upload(path, file, { cacheControl: "3600", upsert: false });
  if (error) {
    return /row-level security|Unauthorized/i.test(error.message)
      ? refusal("class types")
      : { error: error.message };
  }

  const { data: pub } = supabase.storage.from("studio-branding").getPublicUrl(path);
  const { data, error: upErr } = await supabase
    .from("class_types").update({ image_url: pub.publicUrl }).eq("id", id).select("id");
  if (upErr) return { error: upErr.message };
  if (!data?.length) return refusal("class types");

  revalidatePath("/class-types");
  revalidatePath(`/class-types/${id}`);
  return null;
}

export async function saveClassType(_prev: SetupState, fd: FormData): Promise<SetupState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();

  const id = text(fd, "id");
  const name = text(fd, "name");
  if (!name) return { error: "A class type needs a name." };
  const duration_minutes = num(fd, "duration_minutes", 0);
  const default_capacity = num(fd, "default_capacity", 0);
  if (duration_minutes < 1) return { error: "Duration must be at least 1 minute." };
  if (default_capacity < 1) return { error: "Default capacity must be at least 1." };

  const row = {
    name, description: nullable(fd, "description"), duration_minutes, default_capacity,
    difficulty: nullable(fd, "difficulty"), color: nullable(fd, "color"),
    status: text(fd, "status") || "active",
  };

  if (id) {
    const { data, error } = await supabase.from("class_types").update(row).eq("id", id).select("id");
    if (error) return { error: error.message };
    if (!data?.length) return refusal("class types");
  } else {
    const { error } = await supabase.from("class_types").insert({ ...row, studio_id: ctx.studioId });
    if (error) return insertRefused(error) ? refusal("class types") : { error: error.message };
  }
  revalidatePath("/class-types"); revalidatePath("/");
  redirect("/class-types");
}

export async function saveInstructor(_prev: SetupState, fd: FormData): Promise<SetupState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };
  const supabase = createClient();

  const id = text(fd, "id");
  const display_name = text(fd, "display_name");
  if (!display_name) return { error: "An instructor needs a name." };

  const row = {
    display_name,
    bio: nullable(fd, "bio"),
    avatar_url: nullable(fd, "avatar_url"),
    color: nullable(fd, "color"),
    // One per line or comma separated, whichever the owner types.
    certifications: text(fd, "certifications").split(/[\n,]/).map((c) => c.trim()).filter(Boolean),
    status: text(fd, "status") || "active",
  };

  if (id) {
    const { data, error } = await supabase.from("instructors").update(row).eq("id", id).select("id");
    if (error) return { error: error.message };
    if (!data?.length) return refusal("instructors");
  } else {
    // staff_id stays null: an instructor is a teaching record, not a login.
    const { error } = await supabase.from("instructors")
      .insert({ ...row, studio_id: ctx.studioId, staff_id: null });
    if (error) return insertRefused(error) ? refusal("instructors") : { error: error.message };
  }
  revalidatePath("/instructors"); revalidatePath("/");
  redirect("/instructors");
}
