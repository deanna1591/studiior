"use server";

import { createClient } from "@/lib/supabase/server";
import { decryptSecret } from "@/lib/integrations-crypto";
import { getSession } from "@/lib/xendit";

type Supa = ReturnType<typeof createClient>;

/** Read the member's own purchase status (RLS: xpur_member_self). Used by the
 *  poll screen to wait for the callback to flip a pending purchase. */
export async function purchaseStatus(id: string): Promise<string | null> {
  const supabase = createClient();
  return plainStatus(supabase, id);
}

async function plainStatus(supabase: Supa, id: string): Promise<string | null> {
  const { data } = await supabase
    .from("xendit_purchases").select("status").eq("id", id).maybeSingle();
  return data?.status ?? null;
}

/**
 * Decision 40 amendment 8 — confirm on return (the belt). While the purchase is
 * still pending, ask Xendit directly instead of only waiting for the webhook.
 * Runs as the member: xendit_return_check_claim guards it to the member's OWN
 * pending purchase and rate-limits to once per 5s (server-side); if green-lit we
 * GET the session (studio key decrypted from xendit_checkout_context's ciphertext
 * + the env key, exactly as checkout) and, on COMPLETED, activate through the
 * same path the owner's "Check pending payments" uses. ANY failure falls back to
 * the plain status read — webhooks remain the primary path, this is the belt.
 */
export async function confirmWithXendit(id: string): Promise<string | null> {
  const supabase = createClient();
  try {
    const { data: claimData, error: cErr } = await supabase.rpc("xendit_return_check_claim", {
      p_purchase_id: id,
    });
    if (cErr) return plainStatus(supabase, id);
    const claim = (Array.isArray(claimData) ? claimData[0] : claimData) as
      | { status: string; check: boolean; session_id?: string; studio_id?: string }
      | null;
    if (!claim) return plainStatus(supabase, id);
    // Terminal, throttled, or no session attached — nothing to ask Xendit.
    if (!claim.check) return claim.status;
    if (!claim.session_id || !claim.studio_id) return "pending";

    const { data: cctx } = await supabase.rpc("xendit_checkout_context", {
      p_studio_id: claim.studio_id,
    });
    const ctx = (Array.isArray(cctx) ? cctx[0] : cctx) as { secret_key_ciphertext: string } | null;
    if (!ctx?.secret_key_ciphertext) return "pending";
    let secret: string;
    try {
      secret = decryptSecret(ctx.secret_key_ciphertext);
    } catch {
      return "pending";
    }

    const res = await getSession(secret, claim.session_id);
    if (!res.ok) return "pending"; // Xendit unreachable — keep polling, don't error
    const st = (res.data.status ?? "").toUpperCase();
    if (st !== "COMPLETED" && st !== "EXPIRED" && st !== "CANCELED" && st !== "CANCELLED") {
      return "pending"; // still ACTIVE (or unknown) — nothing to apply yet
    }

    const { error: aErr } = await supabase.rpc("xendit_return_check_apply", {
      p_purchase_id: id,
      p_session_status: res.data.status,
      p_payment_id: res.data.payment_id ?? undefined,
    });
    if (aErr) return plainStatus(supabase, id);
    return plainStatus(supabase, id);
  } catch {
    return plainStatus(supabase, id);
  }
}
