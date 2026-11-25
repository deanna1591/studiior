"use server";

import { randomUUID } from "crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createRefund } from "@/lib/xendit";

export type UnclaimedResult = { ok: boolean; message: string };

/** Decision 118: send the set-up email again. Manager-up (the RPC enforces it). */
export async function resendSetup(purchaseId: string): Promise<UnclaimedResult> {
  const { error } = await createClient().rpc("resend_plan_claim", { p_purchase_id: purchaseId });
  if (error) {
    if (error.code === "PT403") return { ok: false, message: "Only owners and managers resend this." };
    if (error.code === "PT409") return { ok: false, message: "This plan is no longer waiting." };
    return { ok: false, message: "Could not send it. Please try again." };
  }
  revalidatePath("/sales/unclaimed");
  return { ok: true, message: "Sent." };
}

/**
 * Decision 118: refund a plan bought without an account, before it is claimed.
 * The full amount goes back through Xendit (the key is decrypted here, never in
 * the browser), the refund is recorded pending, and the waiting plan is
 * cancelled. Manager-up (the RPCs enforce it).
 */
export async function refundUnclaimed(paymentId: string): Promise<UnclaimedResult> {
  const supabase = createClient();
  const { data: ctx, error: cErr } = await supabase.rpc("xendit_refund_context", { p_payment_id: paymentId });
  if (cErr) {
    if (cErr.code === "PT403") return { ok: false, message: "Only owners and managers refund." };
    return { ok: false, message: "Could not start the refund." };
  }
  const c = Array.isArray(ctx) ? ctx[0] : ctx;
  if (!c || !c.is_xendit || !c.payment_ref) return { ok: false, message: "This payment was not taken through Xendit." };
  let secret: string;
  try { secret = decryptSecret(c.secret_key_ciphertext as string); }
  catch { return { ok: false, message: "Online refunds aren't configured on this platform yet." }; }
  const res = await createRefund(secret, {
    referenceId: randomUUID(), paymentId: c.payment_ref as string, reason: "REQUESTED_BY_CUSTOMER",
  });
  if (!res.ok) return { ok: false, message: res.error.message || "Xendit rejected the refund. Nothing changed." };
  const { error: rErr } = await supabase.rpc("refund_payment", {
    p_payment_id: paymentId, p_reason: "Refunded before the plan was claimed",
    p_method: "xendit", p_reference: res.data.refund_id,
  });
  if (rErr) return { ok: false, message: "The refund started at Xendit but could not be recorded." };
  revalidatePath("/sales/unclaimed");
  revalidatePath("/sales");
  return { ok: true, message: "Refunded. The plan will not be added to an account." };
}
