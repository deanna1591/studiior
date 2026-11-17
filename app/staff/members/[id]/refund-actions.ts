"use server";

import { randomUUID } from "crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createRefund } from "@/lib/xendit";

export type RefundResult = { ok: boolean; status?: string; error?: string };

/**
 * Decision 111: refund a payment. The Xendit path decrypts the studio key here,
 * calls POST /v3/refunds, and records the refund pending (the webhook settles
 * it); a studio-recorded refund (method cash/gcash/… + a required reference) is
 * applied at once. Manager-up (the RPCs enforce it).
 */
export async function refundPayment(
  memberId: string,
  paymentId: string,
  amountCents: number | null,
  reason: string | null,
  method: string,
  reference: string | null,
): Promise<RefundResult> {
  const supabase = createClient();

  if (method === "xendit") {
    const { data: ctx, error: cErr } = await supabase.rpc("xendit_refund_context", {
      p_payment_id: paymentId,
    });
    if (cErr) {
      if (cErr.code === "PT403") return { ok: false, error: "Only owners and managers refund." };
      return { ok: false, error: "Could not start the refund." };
    }
    const c = Array.isArray(ctx) ? ctx[0] : ctx;
    if (!c || !c.is_xendit || !c.payment_ref) {
      return { ok: false, error: "This payment was not taken through Xendit." };
    }
    let secret: string;
    try {
      secret = decryptSecret(c.secret_key_ciphertext as string);
    } catch {
      return { ok: false, error: "Online refunds aren't configured on this platform yet." };
    }
    const ourRef = randomUUID();
    const res = await createRefund(secret, {
      referenceId: ourRef,
      paymentId: c.payment_ref as string,
      amountCents: amountCents ?? undefined,
      reason: "REQUESTED_BY_CUSTOMER",
    });
    if (!res.ok) {
      // e.g. PARTIAL_REFUND_NOT_SUPPORTED — show it, write nothing.
      const code = res.error.code ?? "";
      if (code === "PARTIAL_REFUND_NOT_SUPPORTED") {
        return { ok: false, error: "This payment method cannot be partly refunded. Refund the whole amount." };
      }
      return { ok: false, error: res.error.message || "Xendit rejected the refund. Nothing changed." };
    }
    // record pending with the rfd- id as the reference
    const { error: rErr } = await supabase.rpc("refund_payment", {
      p_payment_id: paymentId, p_amount_cents: amountCents ?? undefined,
      p_reason: reason ?? undefined, p_method: "xendit", p_reference: res.data.refund_id,
    });
    if (rErr) return { ok: false, error: "The refund started at Xendit but could not be recorded." };
    revalidatePath(`/members/${memberId}`);
    return { ok: true, status: "pending" };
  }

  // Studio-recorded refund.
  const { data, error } = await supabase.rpc("refund_payment", {
    p_payment_id: paymentId, p_amount_cents: amountCents ?? undefined,
    p_reason: reason ?? undefined, p_method: method, p_reference: reference ?? undefined,
  });
  if (error) {
    if (error.code === "PT403") return { ok: false, error: "Only owners and managers refund." };
    if (error.code === "PT409" && (error.message ?? "").includes("used as credit"))
      return { ok: false, error: "This fee was used as credit, so it cannot be refunded." };
    if (error.code === "PT400" && (error.message ?? "").includes("reference"))
      return { ok: false, error: "A refund reference is required." };
    if (error.code === "PT400") return { ok: false, error: "That is more than is left to refund." };
    if (error.code === "PT409") return { ok: false, error: "This payment cannot be refunded." };
    return { ok: false, error: "Could not record the refund." };
  }
  revalidatePath(`/members/${memberId}`);
  const r = data as unknown as { status?: string } | null;
  return { ok: true, status: r?.status ?? "succeeded" };
}
