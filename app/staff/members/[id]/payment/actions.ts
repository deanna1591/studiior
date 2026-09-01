"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type PayState = { ok: boolean; message: string } | null;

/**
 * Record money the studio has already taken.
 *
 * Decision 16: this is the foundation, not a fallback. A studio in Manila takes
 * GCash and a studio in Prague takes cash at the counter, and neither should
 * need a card processor to run their bookings.
 *
 * Everything it grants — the membership, the pack's credits, the audit row —
 * happens inside record_manual_payment(), which calls the same
 * activate_purchase() the Stripe webhook calls. Front desk and above, per §9.
 */
export async function recordPayment(_prev: PayState, fd: FormData): Promise<PayState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const memberId = String(fd.get("member_id") ?? "");
  const kind = String(fd.get("kind") ?? "other");
  const planId = String(fd.get("plan_id") ?? "");
  const bookingId = String(fd.get("booking_id") ?? "");
  const method = String(fd.get("method") ?? "cash");

  // Entered in whole units, stored in cents. §: money is integer cents and
  // never a float, so the parse happens once, here, and rounds explicitly.
  const raw = String(fd.get("amount") ?? "").trim().replace(/,/g, "");
  const amount = Math.round(Number(raw) * 100);
  if (!raw || !Number.isFinite(amount) || amount < 0) {
    return { ok: false, message: "How much was taken?" };
  }
  if (kind === "plan" && !planId) {
    return { ok: false, message: "Choose what they bought." };
  }

  const paidOn = String(fd.get("paid_at") ?? "").trim();

  const supabase = createClient();
  const { error } = await supabase.rpc("record_manual_payment", {
    p_studio_id: ctx.studioId,
    p_member_id: memberId,
    p_kind: kind,
    p_amount_cents: amount,
    p_method: method,
    p_plan_id: planId || undefined,
    p_booking_id: bookingId || undefined,
    p_method_note: String(fd.get("method_note") ?? "").trim() || undefined,
    p_reference: String(fd.get("reference") ?? "").trim() || undefined,
    p_paid_at: paidOn ? new Date(paidOn).toISOString() : undefined,
  });

  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "You are not allowed to record payments." }
      : { ok: false, message: error.message };
  }

  revalidatePath(`/members/${memberId}`);
  redirect(`/members/${memberId}?recorded=1`);
}

/**
 * Give money back. Owner and manager only — §9 keeps refunds away from front
 * desk so money leaving the studio needs a second pair of hands.
 *
 * For a Stripe payment this records the refund; the money itself moves in the
 * studio's own Stripe dashboard, which is where their reconciliation already
 * happens. For a manual payment there is nothing else to move.
 */
export async function refundPayment(_prev: PayState, fd: FormData): Promise<PayState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const paymentId = String(fd.get("payment_id") ?? "");
  const memberId = String(fd.get("member_id") ?? "");
  const raw = String(fd.get("amount") ?? "").trim().replace(/,/g, "");
  const amount = raw ? Math.round(Number(raw) * 100) : null;

  const supabase = createClient();
  const { error } = await supabase.rpc("record_refund", {
    p_payment_id: paymentId,
    p_amount_cents: amount ?? undefined,
    p_reason: String(fd.get("reason") ?? "").trim() || undefined,
  });

  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "Refunds are the owner's or a manager's to make." }
      : { ok: false, message: error.message };
  }

  revalidatePath(`/members/${memberId}`);
  return { ok: true, message: "Refund recorded." };
}
