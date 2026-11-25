import { randomUUID } from "crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createRefund } from "@/lib/xendit";

type Claim = {
  ok?: boolean; reason?: string;
  claimed?: { purchase_id: string; plan_name: string }[];
  refunds?: { purchase_id: string; xendit_payment_id: string | null; plan_name: string }[];
  secret_key_ciphertext?: string | null;
};

/**
 * Decision 118: attach every plan paid for under this member's VERIFIED email
 * (claim_waiting_plans). An intro offer they are not eligible for is not
 * attached; this server refunds it in full through Xendit (the key is decrypted
 * here, never in the browser) and records it, which emails the buyer "We have
 * refunded your payment". Never throws: a sign-in must not fail because a claim
 * could not finish; a refund that did not go through stays on the staff list
 * and the daily check.
 */
export async function claimWaitingPlans(
  supabase: SupabaseClient, studioId: string,
): Promise<{ claimed: string[]; refunded: string[] }> {
  const out = { claimed: [] as string[], refunded: [] as string[] };
  try {
    const { data, error } = await supabase.rpc("claim_waiting_plans", { p_studio_id: studioId });
    if (error || !data) return out;
    const r = data as Claim;
    out.claimed = (r.claimed ?? []).map((c) => c.plan_name);
    const refunds = (r.refunds ?? []).filter((x) => x.xendit_payment_id);
    if (refunds.length === 0 || !r.secret_key_ciphertext) return out;
    let secret: string;
    try { secret = decryptSecret(r.secret_key_ciphertext); } catch { return out; }
    for (const f of refunds) {
      const res = await createRefund(secret, {
        referenceId: randomUUID(), paymentId: f.xendit_payment_id as string, reason: "REQUESTED_BY_CUSTOMER",
      });
      if (!res.ok) continue;
      const { error: rErr } = await supabase.rpc("record_guest_intro_refund", {
        p_purchase_id: f.purchase_id, p_reference: res.data.refund_id,
      });
      if (!rErr) out.refunded.push(f.plan_name);
    }
  } catch {
    /* never block a sign-in on a claim */
  }
  return out;
}
