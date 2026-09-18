"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type RateState = { ok: boolean; message: string } | null;

// Whole currency units -> integer cents; blank/NaN -> the fallback.
function cents(v: FormDataEntryValue | null, fallback: number | null): number | null {
  const s = String(v ?? "").trim();
  if (s === "") return fallback;
  const n = Number(s);
  return Number.isFinite(n) ? Math.max(0, Math.round(n * 100)) : fallback;
}
function intOf(v: FormDataEntryValue | null, fallback: number): number {
  const n = Number(String(v ?? "").trim());
  return Number.isFinite(n) ? Math.max(0, Math.round(n)) : fallback;
}

/**
 * A new immutable rate version (Decision 22). set_instructor_rate INSERTs — it
 * never edits an existing version, and refuses (PT409) a second version on the
 * same effective date, because a pay record already points at the first.
 */
export async function saveRate(_prev: RateState, fd: FormData): Promise<RateState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const instructorId = String(fd.get("instructor_id") ?? "");
  const effectiveFrom = String(fd.get("effective_from") ?? "").trim();
  if (!effectiveFrom) return { ok: false, message: "Pick an effective date." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_instructor_rate", {
    p_instructor_id: instructorId,
    p_effective_from: effectiveFrom,
    p_base_rate_cents: cents(fd.get("base"), 0)!,
    p_per_head_rate_cents: cents(fd.get("per_head_rate"), 0)!,
    p_per_head_threshold: intOf(fd.get("per_head_threshold"), 0),
    p_full_house_bonus_cents: cents(fd.get("full_house_bonus"), 0)!,
    p_private_rate_cents: cents(fd.get("private_rate"), null) ?? undefined,
    p_duo_rate_cents: cents(fd.get("duo_rate"), null) ?? undefined,
    p_trio_rate_cents: cents(fd.get("trio_rate"), null) ?? undefined,
    p_pay_tier: String(fd.get("pay_tier") ?? "").trim() || undefined,
    p_note: String(fd.get("note") ?? "").trim() || undefined,
  });
  if (error) return { ok: false, message: error.message };
  if (!(data as { ok?: boolean })?.ok) return { ok: false, message: "Nothing was saved." };
  revalidatePath(`/instructors/${instructorId}`);
  return { ok: true, message: `Saved. In force from ${effectiveFrom}.` };
}

/**
 * Copy this instructor's latest rate to every OTHER active instructor, one new
 * version each through set_instructor_rate — so one contract for nine people is
 * entered once, not typed nine times. An instructor who already has a version on
 * that effective date is skipped (PT409), never overwritten.
 */
export async function copyRateToAll(_prev: RateState, fd: FormData): Promise<RateState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const sourceId = String(fd.get("instructor_id") ?? "");
  const supabase = createClient();

  const { data: src } = await supabase.from("instructor_rate_versions")
    .select("effective_from, base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents, private_rate_cents, duo_rate_cents, trio_rate_cents, pay_tier")
    .eq("instructor_id", sourceId).order("effective_from", { ascending: false }).limit(1).maybeSingle();
  if (!src) return { ok: false, message: "This instructor has no rate to copy yet." };

  const { data: others } = await supabase.from("instructors")
    .select("id").eq("studio_id", ctx.studioId).eq("status", "active").neq("id", sourceId);
  const list = others ?? [];

  let created = 0, skipped = 0;
  for (const o of list) {
    const { data, error } = await supabase.rpc("set_instructor_rate", {
      p_instructor_id: o.id,
      p_effective_from: src.effective_from,
      p_base_rate_cents: src.base_rate_cents,
      p_per_head_rate_cents: src.per_head_rate_cents,
      p_per_head_threshold: src.per_head_threshold,
      p_full_house_bonus_cents: src.full_house_bonus_cents,
      p_private_rate_cents: src.private_rate_cents ?? undefined,
      p_duo_rate_cents: src.duo_rate_cents ?? undefined,
      p_trio_rate_cents: src.trio_rate_cents ?? undefined,
      p_pay_tier: src.pay_tier ?? undefined,
      p_note: "Copied from a colleague's rate",
    });
    if (error) { skipped += 1; continue; }              // PT409 (already has one) or refused
    if ((data as { ok?: boolean })?.ok) created += 1; else skipped += 1;
  }
  revalidatePath(`/instructors/${sourceId}`);
  return {
    ok: true,
    message: `Copied to ${created} instructor${created === 1 ? "" : "s"}`
      + (skipped ? `; ${skipped} already had a rate from ${src.effective_from} and were left alone.` : "."),
  };
}
