"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { fields, invalid, insertSeriesRow } from "@/app/staff/series/shared";

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
  | { ok: true; message: string; seriesId: string; warnings: string[] }
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
  // 144: the tier control is only present when the studio has guarantees/flex on;
  // absent, nothing is sent and the class is created core.
  const tier = String(fd.get("tier") ?? "").trim();
  const minBookings = String(fd.get("min_bookings") ?? "").trim();
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
    p_tier: tier === "" ? undefined : (tier as "core" | "flex" | "always"),
    p_min_bookings: minBookings === "" ? undefined : Number(minBookings),
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
      + (warnings.includes("standalone_flex")
          ? " It is a standalone flex class — no other class of that instructor beside it — so it carries a standby fee."
          : "")
      + (warnings.includes("outside_availability")
          ? " It is outside the hours they have said they work — they have not been told."
          : ""),
  };
}

/**
 * Decision 37 — the SAME slot, made repeating. It goes through the one series
 * creator `/series/new` uses (`insertSeriesRow`, whose 057 trigger materialises
 * a year and 061 assigns), never a second one; the tier is applied through the
 * existing `set_series_guarantee()`, exactly as the series detail page does.
 *
 * The name is the class type's — the calendar form does not ask for one, the way
 * the one-off derives its occurrence name from the class type. Capacity and
 * duration fall back to the class type's own when the form leaves them blank.
 */
async function createSeriesFromSlot(fd: FormData): Promise<CreateState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const classTypeId = String(fd.get("class_type_id") ?? "");
  if (!classTypeId) return { ok: false, message: "Pick what kind of class this is." };

  const supabase = createClient();
  const { data: ct } = await supabase.from("class_types")
    .select("name, duration_minutes, default_capacity").eq("id", classTypeId).maybeSingle();
  if (!ct) return { ok: false, message: "That class type no longer exists." };

  // Fill the fields the calendar form leaves to the class type, then hand the
  // whole thing to the shared validation and insert — one series creator.
  fd.set("name", ct.name);
  if (!String(fd.get("duration_minutes") ?? "").trim()) fd.set("duration_minutes", String(ct.duration_minutes));
  if (!String(fd.get("capacity") ?? "").trim()) fd.set("capacity", String(ct.default_capacity));

  const f = fields(fd);
  const bad = invalid(f);
  if (bad) return { ok: false, message: bad };
  if (!f.p_ends_on) return { ok: false, message: "Pick the date the series runs until." };

  const res = await insertSeriesRow(ctx.studioId, f);
  if (!res.ok) return { ok: false, message: res.error };

  // The tier, through the canonical per-series writer — only when the studio has
  // a guarantee switch on (the tier control is absent otherwise, so nothing is
  // sent and the series stays core). set_series_guarantee reaches the occurrences
  // the trigger just made and returns the standalone-flex count.
  const tier = String(fd.get("tier") ?? "").trim();
  const minBookings = String(fd.get("min_bookings") ?? "").trim();
  const warnings: string[] = [];
  if (tier === "flex" || tier === "always" || (tier === "core" && minBookings !== "")) {
    const { data: g } = await supabase.rpc("set_series_guarantee", {
      p_series_id: res.id,
      p_tier: tier as "core" | "flex" | "always",
      p_min_bookings: minBookings === "" ? undefined : Number(minBookings),
    });
    const gr = g as unknown as { standalone_count?: number } | null;
    if (tier === "flex" && (gr?.standalone_count ?? 0) > 0) warnings.push("standalone_flex");
  }

  revalidatePath("/series"); revalidatePath("/schedule"); revalidatePath("/");
  return {
    ok: true,
    seriesId: res.id,
    warnings,
    message: "Repeating class created. Its year of classes is on the calendar now."
      + (warnings.includes("standalone_flex")
          ? " Some are standalone flex classes — no other class of that instructor beside them — so they carry a standby fee."
          : ""),
  };
}

/**
 * The one action the create form posts to. It branches on the "Repeats weekly"
 * toggle: OFF is the unchanged one-off `create_occurrence()` path, ON is the
 * series path above. One dispatcher so the form binds a single action.
 */
export async function createFromSlot(prev: CreateState, fd: FormData): Promise<CreateState> {
  if (String(fd.get("repeats") ?? "") === "on") return createSeriesFromSlot(fd);
  return createOnSlot(prev, fd);
}
