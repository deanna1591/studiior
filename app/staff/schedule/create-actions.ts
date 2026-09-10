"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

/**
 * Creating a class from an empty slot on the calendar.
 *
 * The slot supplies the date, the time and whose column it is; the form asks
 * only for what it cannot infer. Everything goes through `create_occurrence()`,
 * which is the same gate `move_occurrence()` uses — creation must not bypass
 * rules that editing enforces, and until migration 089 it did: `createClass`
 * was a bare INSERT with no validity window, no availability check, and a clash
 * surfacing as a raw Postgres error.
 *
 * ONE-OFF ONLY. No rule is written and `series_id` stays null. A calendar that
 * silently created a year of classes from one click would be a bad surprise;
 * recurring belongs at /series where the whole rule is visible.
 */
export type CreateState =
  | { ok: true; message: string; occurrenceId: string; warnings: string[] }
  | { ok: false; message: string; blockedBy?: { occurrenceId?: string; name?: string; at?: string; who?: string; room?: string } }
  | { ok: false; needRoom: true; rooms: { id: string; name: string; capacity: number }[]; message: string }
  | null;

const say = (m: string) =>
  /PT403/.test(m) ? "Only owners and managers add classes."
  : /PT402/.test(m) ? "This studio's Studiior subscription is not active."
  : /PT400|PT422/.test(m) ? m.replace(/^.*?:\s*/, "")
  : m;

export async function createOnSlot(_prev: CreateState, fd: FormData): Promise<CreateState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const startsAt = String(fd.get("starts_at") ?? "");
  const endsAt = String(fd.get("ends_at") ?? "");
  const classTypeId = String(fd.get("class_type_id") ?? "");
  const instructorId = String(fd.get("instructor_id") ?? "");
  const roomId = String(fd.get("room_id") ?? "");
  const capacity = String(fd.get("capacity") ?? "").trim();
  if (!classTypeId) return { ok: false, message: "Pick what kind of class this is." };
  if (!startsAt || !endsAt) return { ok: false, message: "That slot has no time on it." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("create_occurrence", {
    p_studio_id: ctx.studioId,
    p_class_type_id: classTypeId,
    p_starts_at: startsAt,
    p_ends_at: endsAt,
    // An empty string is the Unassigned column, which is an open shift, not a
    // missing value — so it becomes an explicit null rather than being omitted.
    p_instructor_id: instructorId || undefined,
    p_room_id: roomId || undefined,
    p_capacity: capacity === "" ? undefined : Number(capacity),
  });
  if (error) return { ok: false, message: say(error.message) };

  const r = data as unknown as {
    ok?: boolean; reason?: string; occurrence_id?: string; local_when?: string;
    warnings?: string[]; rooms?: { id: string; name: string; capacity: number }[];
    blocked_by?: { occurrence_id?: string; name?: string; at?: string; who?: string;
                   room?: string; on?: string };
  };

  if (!r?.ok) {
    if (r?.reason === "room_required") {
      return {
        ok: false, needRoom: true, rooms: r.rooms ?? [],
        message: "Which room? A class with no room is the one thing that can be double-booked.",
      };
    }
    if (r?.reason === "outside_availability_dates") {
      return {
        ok: false,
        message: `${r.blocked_by?.who ?? "That instructor"} has not agreed to work on `
               + `${r.blocked_by?.on ?? "that date"}. That is dates they never agreed to, not hours — `
               + `it cannot be overridden here.`,
      };
    }
    const busy = r?.reason === "room_busy" ? "That room is already in use then."
               : r?.reason === "instructor_busy" ? "They are already teaching then."
               : "That class could not be created.";
    return { ok: false, message: busy, blockedBy: r?.blocked_by };
  }

  revalidatePath("/schedule"); revalidatePath("/");
  const warnings = r.warnings ?? [];
  return {
    ok: true,
    occurrenceId: r.occurrence_id!,
    warnings,
    message: `Added, ${r.local_when}.`
      + (warnings.includes("outside_availability")
          ? " It is outside the hours they have said they work — they have not been told."
          : ""),
  };
}
