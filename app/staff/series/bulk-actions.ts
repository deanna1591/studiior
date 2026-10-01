"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import type { Json } from "@/lib/database.types";

export type BulkRow = { series_id: string; name: string; when: string; current?: string; new?: string; reason?: string };
export type BulkResult =
  | { ok: true; preview: boolean; changed: BulkRow[]; refused: BulkRow[]; warnings: { series_id: string; code: string }[] }
  | { error: string }
  | null;

/**
 * Decision 42b — one change to many recurring classes. The form carries the
 * selected series ids, a change type, and the one matching value; this builds
 * the single-key p_change and calls bulk_update_series (preview or apply). The
 * database runs each series through the same single-series function, so the
 * rules are the database's, not ours.
 */
function buildChange(fd: FormData): Record<string, unknown> | { error: string } {
  const ct = String(fd.get("change_type") ?? "");
  const v = (k: string) => { const s = String(fd.get(k) ?? "").trim(); return s === "" ? null : s; };
  switch (ct) {
    case "minimum": {
      const m = v("minimum");
      if (m === null || !/^\d+$/.test(m)) return { error: "Enter a minimum." };
      return { minimum: Number(m) };
    }
    case "tier": {
      const t = v("tier");
      if (t !== "core" && t !== "flex" && t !== "always") return { error: "Pick a tier." };
      const m = v("minimum");
      if (t === "flex" && (m === null || !/^\d+$/.test(m) || Number(m) < 1))
        return { error: "A flex tier needs a minimum of at least one." };
      return { tier: t, minimum: t === "flex" ? Number(m) : null };
    }
    case "room": {
      const r = v("room_id");
      if (r === null) return { error: "Pick a room." };
      return { room_id: r };
    }
    case "ends_on":   return { ends_on: v("ends_on") };       // empty = no end
    case "starts_on": {
      const d = v("starts_on");
      if (d === null) return { error: "Pick a start date." };
      return { starts_on: d };
    }
    case "instructor": return { instructor_id: v("instructor_id") };  // empty = Unassigned
    default: return { error: "Pick what to change." };
  }
}

async function run(fd: FormData, preview: boolean): Promise<BulkResult> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "You are not signed in." };
  const ids = fd.getAll("ids").map(String).filter(Boolean);
  if (ids.length === 0) return { error: "Select at least one recurring class." };
  const change = buildChange(fd);
  if ("error" in change) return { error: (change as { error: string }).error };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("bulk_update_series", {
    p_series_ids: ids, p_change: change as Json, p_preview: preview,
  });
  if (error) {
    return {
      error: /PT403/.test(error.message) ? "Those are not all recurring classes you manage."
        : /PT422/.test(error.message) ? "That change cannot be applied."
        : error.message,
    };
  }
  if (!preview) { revalidatePath("/series"); revalidatePath("/schedule"); revalidatePath("/"); }
  const r = data as unknown as Extract<BulkResult, { ok: true }>;
  return { ...r, preview };
}

export async function previewBulk(_prev: BulkResult, fd: FormData): Promise<BulkResult> {
  return run(fd, true);
}
export async function applyBulk(_prev: BulkResult, fd: FormData): Promise<BulkResult> {
  return run(fd, false);
}
