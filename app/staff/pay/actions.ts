"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";

export type PayState = { ok: boolean; message: string } | null;

/**
 * Record that the studio paid an instructor for a closed period — the date, how,
 * a reference, and optionally the receipt. Studiior does not move money; this is
 * a record of a payment made elsewhere (Decision 22 stands).
 */
export async function markPaid(_prev: PayState, fd: FormData): Promise<PayState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const periodId = String(fd.get("period_id") ?? "");
  const instructorId = String(fd.get("instructor_id") ?? "");
  const paidOn = String(fd.get("paid_on") ?? "");
  const method = String(fd.get("method") ?? "");
  const reference = String(fd.get("reference") ?? "").trim() || null;
  if (!paidOn) return { ok: false, message: "When was it paid?" };

  const supabase = createClient();

  // Optional receipt → the private bucket, path <studio>/<instructor>/<file>.
  let proofPath: string | null = null;
  const file = fd.get("proof") as File | null;
  if (file && file.size > 0) {
    if (file.size > 5_000_000) return { ok: false, message: "That file is over 5 MB." };
    const ext = file.name.split(".").pop()?.toLowerCase() ?? "pdf";
    const path = `${ctx.studioId}/${instructorId}/${periodId}-${Date.now()}.${ext}`;
    const { error: upErr } = await supabase.storage.from("instructor-pay-proofs")
      .upload(path, file, { cacheControl: "3600", upsert: false });
    if (upErr) return { ok: false, message: /row-level security|Unauthorized/i.test(upErr.message) ? "Only owners and managers can attach a receipt." : upErr.message };
    proofPath = path;
  }

  const { data, error } = await supabase.rpc("record_pay_settlement", {
    p_period_id: periodId, p_instructor_id: instructorId, p_paid_on: paidOn,
    p_method: method, p_reference: reference ?? undefined, p_proof_path: proofPath ?? undefined,
  });
  if (error) return { ok: false, message: error.message };
  const r = data as unknown as { ok?: boolean } | null;
  if (!r?.ok) return { ok: false, message: "That could not be recorded." };
  revalidatePath(`/pay/${periodId}`);
  return { ok: true, message: "Recorded. The instructor sees their statement marked paid." };
}

export type CloseState = { ok: boolean; message?: string; held?: { name: string; when: string; instructor: string }[] } | null;

/**
 * Decision 75b-2 (h): close a pay period. close_pay_period refuses while any
 * class record is held (an instructor has not checked in, or a manager has not
 * released it) and returns the holdouts as a REASON — we show the list, not an
 * error toast. Manager-up; the DB is the boundary.
 */
export async function closePeriod(_prev: CloseState, fd: FormData): Promise<CloseState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "Not signed in." };
  const periodId = String(fd.get("period_id") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase.rpc("close_pay_period", { p_period_id: periodId });
  if (error) {
    if (error.code === "PT403") return { ok: false, message: "Only owners and managers close a period." };
    if (error.code === "PT409") return { ok: false, message: error.message };
    return { ok: false, message: error.message };
  }
  const r = data as unknown as { ok: boolean; reason?: string; classes?: { name: string; when: string; instructor: string }[] } | null;
  if (r && !r.ok && r.reason === "held_records") {
    return { ok: false, message: "This period still has classes waiting on a check-in.", held: r.classes ?? [] };
  }
  revalidatePath(`/pay/${periodId}`);
  return { ok: true, message: "Period closed. Corrections from here are adjustments in the next period." };
}
