"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type PromoState = { ok: boolean; message: string } | null;

type Result = { ok: boolean; reason?: string; message?: string } | null;

function done(r: Result, ok: string): PromoState {
  if (r?.ok) {
    revalidatePath("/settings/promotions");
    return { ok: true, message: ok };
  }
  return { ok: false, message: r?.message ?? "That could not be saved." };
}

/** Decision 117 — create, or edit before it starts. The database decides the rules. */
export async function savePromotion(_prev: PromoState, fd: FormData): Promise<PromoState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const id = String(fd.get("id") ?? "") || null;
  const pct = Number(String(fd.get("pct") ?? ""));
  const supabase = createClient();
  const { data, error } = await supabase.rpc("promotion_save", {
    p_studio_id: ctx.studioId,
    p_promotion_id: id as unknown as string,
    p_name: String(fd.get("name") ?? ""),
    p_pct: Number.isFinite(pct) ? Math.trunc(pct) : 0,
    p_starts_on: String(fd.get("starts_on") ?? ""),
    p_ends_on: String(fd.get("ends_on") ?? ""),
    p_plan_ids: fd.getAll("plan_ids").map(String),
  });
  if (error) {
    return { ok: false, message: /PT403/.test(error.code ?? "") ? "Only owners and managers set promotions." : error.message };
  }
  return done(data as Result, id ? "Promotion updated." : "Promotion saved.");
}

export async function endPromotion(_prev: PromoState, fd: FormData): Promise<PromoState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("promotion_end_now", { p_promotion_id: String(fd.get("id") ?? "") });
  if (error) return { ok: false, message: error.message };
  return done(data as Result, "Promotion ended. New checkouts pay the list price.");
}

export async function archivePromotion(_prev: PromoState, fd: FormData): Promise<PromoState> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("promotion_archive", { p_promotion_id: String(fd.get("id") ?? "") });
  if (error) return { ok: false, message: error.message };
  return done(data as Result, "Promotion archived.");
}
