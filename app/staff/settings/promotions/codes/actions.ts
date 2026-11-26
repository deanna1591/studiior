"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext, isManagerUp } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type CodeState = { ok: boolean; message: string; batchId?: string } | null;

function planIds(fd: FormData) { return fd.getAll("plan_ids").map(String).filter(Boolean); }
function productIds(fd: FormData) { return fd.getAll("product_ids").map(String).filter(Boolean); }

/** Decision 120: a batch of unique single-use codes. */
export async function createBatch(_prev: CodeState, fd: FormData): Promise<CodeState> {
  const ctx = await getStaffContext();
  if (!ctx || !isManagerUp(ctx.role)) return { ok: false, message: "Only owners and managers create codes." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("discount_code_create_batch", {
    p_studio_id: ctx.studioId, p_name: String(fd.get("name") ?? ""), p_pct: Number(fd.get("pct")),
    p_count: Number(fd.get("count")), p_starts: String(fd.get("starts_on") ?? ""), p_ends: String(fd.get("ends_on") ?? ""),
    p_plan_ids: planIds(fd), p_private: fd.get("private_sessions") === "on", p_product_ids: productIds(fd),
  });
  if (error) return { ok: false, message: error.message };
  const r = data as { ok: boolean; message?: string; batch_id?: string; count?: number };
  if (!r.ok) return { ok: false, message: r.message ?? "That didn't work." };
  revalidatePath("/settings/promotions/codes");
  return { ok: true, message: `${r.count} codes made.`, batchId: r.batch_id };
}

/** Decision 120: one owner-chosen code with a maximum number of uses. */
export async function createShared(_prev: CodeState, fd: FormData): Promise<CodeState> {
  const ctx = await getStaffContext();
  if (!ctx || !isManagerUp(ctx.role)) return { ok: false, message: "Only owners and managers create codes." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("discount_code_create_shared", {
    p_studio_id: ctx.studioId, p_code: String(fd.get("code") ?? ""), p_name: String(fd.get("name") ?? ""),
    p_pct: Number(fd.get("pct")), p_starts: String(fd.get("starts_on") ?? ""), p_ends: String(fd.get("ends_on") ?? ""),
    p_plan_ids: planIds(fd), p_max_uses: Number(fd.get("max_uses")), p_private: fd.get("private_sessions") === "on",
    p_product_ids: productIds(fd),
  });
  if (error) return { ok: false, message: error.message };
  const r = data as { ok: boolean; message?: string; batch_id?: string; code?: string };
  if (!r.ok) return { ok: false, message: r.message ?? "That didn't work." };
  revalidatePath("/settings/promotions/codes");
  return { ok: true, message: `${r.code} is ready.`, batchId: r.batch_id };
}

/** Decision 120: cancel an unused code. */
export async function cancelCode(codeId: string, batchId: string): Promise<{ ok: boolean; message?: string }> {
  const ctx = await getStaffContext();
  if (!ctx || !isManagerUp(ctx.role)) return { ok: false, message: "Only owners and managers cancel codes." };
  const supabase = createClient();
  const { data, error } = await supabase.rpc("discount_code_cancel", { p_code_id: codeId });
  if (error) return { ok: false, message: error.message };
  const r = data as { ok: boolean; message?: string };
  revalidatePath(`/settings/promotions/codes/${batchId}`);
  return r;
}
