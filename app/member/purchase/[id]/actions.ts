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
  // Best-effort: record WHY a return-check did nothing, so a stuck purchase names
  // its own failure instead of hiding behind a silent 200 (Decision 40 amdt 9).
  const note = async (r: string) => {
    try { await supabase.rpc("xendit_return_check_note", { p_purchase_id: id, p_result: r }); }
    catch { /* never let the note itself mask the outcome */ }
  };
  try {
    const { data: claimData, error: cErr } = await supabase.rpc("xendit_return_check_claim", {
      p_purchase_id: id,
    });
    if (cErr) { await note("claim_failed:" + (cErr.code || "err")); return plainStatus(supabase, id); }
    const claim = (Array.isArray(claimData) ? claimData[0] : claimData) as
      | { status: string; check: boolean; session_id?: string; studio_id?: string }
      | null;
    if (!claim) return plainStatus(supabase, id);
    // Terminal, throttled, or no session attached — nothing to ask Xendit.
    if (!claim.check) return claim.status;
    if (!claim.session_id || !claim.studio_id) { await note("no_session"); return "pending"; }

    const { data: cctx, error: ctxErr } = await supabase.rpc("xendit_checkout_context", {
      p_studio_id: claim.studio_id,
    });
    if (ctxErr) { await note("context_failed:" + (ctxErr.code || "err")); return "pending"; }
    const ctx = (Array.isArray(cctx) ? cctx[0] : cctx) as { secret_key_ciphertext: string } | null;
    if (!ctx?.secret_key_ciphertext) { await note("no_ciphertext"); return "pending"; }
    let secret: string;
    try {
      secret = decryptSecret(ctx.secret_key_ciphertext);
    } catch {
      await note("decrypt_failed"); return "pending";
    }

    const res = await getSession(secret, claim.session_id);
    if (!res.ok) { await note("get_failed:" + res.error.status); return "pending"; } // 0 = network
    const st = (res.data.status ?? "").toUpperCase();
    if (st !== "COMPLETED" && st !== "EXPIRED" && st !== "CANCELED" && st !== "CANCELLED") {
      await note("session_" + (st ? st.toLowerCase() : "unknown")); // still ACTIVE — nothing to apply
      return "pending";
    }

    const { error: aErr } = await supabase.rpc("xendit_return_check_apply", {
      p_purchase_id: id,
      p_session_status: res.data.status,
      p_payment_id: res.data.payment_id ?? undefined,
    });
    if (aErr) { await note("apply_failed:" + (aErr.code || "err")); return plainStatus(supabase, id); }
    return plainStatus(supabase, id); // apply set last_return_check_result
  } catch (e) {
    await note("action_threw:" + (e instanceof Error ? e.name : "unknown"));
    return plainStatus(supabase, id);
  }
}
