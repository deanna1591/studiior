"use server";

import { revalidatePath } from "next/cache";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { encryptSecret, decryptSecret, sha256Hex } from "@/lib/integrations-crypto";
import { getBalance, getSession } from "@/lib/xendit";

export type XenditState = { ok: boolean; message: string } | null;

/**
 * Connect Xendit for this studio. Owner-only (enforced by RLS on
 * studio_payment_providers, not by this action — a check here is a promise, a
 * check in the policy is the rule). The secret key is verified against Xendit
 * (GET /balance) BEFORE it is stored, so a bad key is rejected at connect; then
 * both secrets are AES-GCM encrypted and only ciphertext + the token's sha256
 * reach the database. The plaintext is never logged or echoed.
 */
export async function connectXendit(_prev: XenditState, fd: FormData): Promise<XenditState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const secret = String(fd.get("secret_key") ?? "").trim();
  const token = String(fd.get("callback_token") ?? "").trim();
  const testMode = fd.get("test_mode") != null;
  if (!secret || !token) {
    return { ok: false, message: "Paste both the secret key and the callback verification token." };
  }

  const bal = await getBalance(secret);
  if (!bal.ok) {
    return {
      ok: false,
      message: bal.error.status === 401
        ? "Xendit rejected that secret key — check you pasted the right one for this mode."
        : `Could not reach Xendit to verify the key: ${bal.error.message}`,
    };
  }

  const supabase = createClient();
  const { error } = await supabase.from("studio_payment_providers").upsert(
    {
      studio_id: ctx.studioId,
      provider: "xendit",
      secret_key_ciphertext: encryptSecret(secret),
      callback_token_ciphertext: encryptSecret(token),
      callback_token_sha256: sha256Hex(token),
      key_last4: secret.slice(-4),
      test_mode: testMode,
      connected_by: ctx.userId,
      last_verified_at: new Date().toISOString(),
    },
    { onConflict: "studio_id,provider" },
  );
  if (error) {
    return /row-level|permission|PT/i.test(error.message)
      ? { ok: false, message: "Only the studio owner can connect a payment provider." }
      : { ok: false, message: error.message };
  }
  revalidatePath("/settings/xendit");
  return { ok: true, message: "Xendit is connected." };
}

/** Re-verify the stored key against Xendit and stamp last_verified_at. */
export async function testXenditConnection(_prev: XenditState, _fd: FormData): Promise<XenditState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { data: row } = await supabase
    .from("studio_payment_providers")
    .select("secret_key_ciphertext")
    .eq("studio_id", ctx.studioId).eq("provider", "xendit").maybeSingle();
  if (!row) return { ok: false, message: "Xendit is not connected." };

  const bal = await getBalance(decryptSecret(row.secret_key_ciphertext));
  if (!bal.ok) {
    return { ok: false, message: bal.error.status === 401
      ? "Xendit no longer accepts the stored key — reconnect with a fresh one."
      : `Could not reach Xendit: ${bal.error.message}` };
  }
  await supabase.from("studio_payment_providers")
    .update({ last_verified_at: new Date().toISOString() })
    .eq("studio_id", ctx.studioId).eq("provider", "xendit");
  revalidatePath("/settings/xendit");
  return { ok: true, message: "Connection is good — Xendit accepted the key." };
}

/** Disconnect: remove the stored secrets. Owner-only via RLS. */
export async function disconnectXendit(_prev: XenditState, _fd: FormData): Promise<XenditState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();
  const { error } = await supabase.from("studio_payment_providers")
    .delete().eq("studio_id", ctx.studioId).eq("provider", "xendit");
  if (error) return { ok: false, message: error.message };
  revalidatePath("/settings/xendit");
  return { ok: true, message: "Xendit is disconnected." };
}

/**
 * Owner-triggered reconcile: ask Xendit the status of this studio's pending
 * purchases and apply the outcome (the automatic sweep only expires locally —
 * see Decision 40). Owner session decrypts THIS studio's own key; the outcome
 * is applied through xendit_apply_session (manager-up guarded in SQL).
 */
export async function syncPendingXendit(_prev: XenditState, _fd: FormData): Promise<XenditState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const supabase = createClient();

  const { data: prov } = await supabase
    .from("studio_payment_providers")
    .select("secret_key_ciphertext")
    .eq("studio_id", ctx.studioId).eq("provider", "xendit").maybeSingle();
  if (!prov) return { ok: false, message: "Xendit is not connected." };

  const { data: pending } = await supabase
    .from("xendit_purchases")
    .select("id, payment_session_id")
    .eq("studio_id", ctx.studioId).eq("status", "pending");
  if (!pending || pending.length === 0) return { ok: true, message: "No pending payments to check." };

  const secret = decryptSecret(prov.secret_key_ciphertext);
  let updated = 0;
  for (const p of pending) {
    if (!p.payment_session_id) continue;
    const s = await getSession(secret, p.payment_session_id);
    if (!s.ok) continue;
    if (["COMPLETED", "EXPIRED", "CANCELED", "CANCELLED"].includes(s.data.status)) {
      const { error } = await supabase.rpc("xendit_apply_session", {
        p_purchase_id: p.id,
        p_session_status: s.data.status,
        p_payment_id: s.data.payment_id ?? undefined,
      });
      if (!error) updated += 1;
    }
  }

  // Also re-run resolution on any events we stored as ignored before the
  // reference-resolution fix — activates a pending purchase from its stored
  // event without a fresh callback (Decision 40 amendment 4).
  const { data: rep } = await supabase.rpc("xendit_reprocess_ignored", { p_studio_id: ctx.studioId });
  const reprocessed = (rep as { reprocessed?: number } | null)?.reprocessed ?? 0;

  revalidatePath("/settings/xendit");
  const extra = reprocessed ? `, ${reprocessed} recovered from stored events` : "";
  return { ok: true, message: `Checked ${pending.length} pending — ${updated} resolved${extra}.` };
}
