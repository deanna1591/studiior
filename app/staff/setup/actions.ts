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
