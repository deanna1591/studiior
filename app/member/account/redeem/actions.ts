"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type RedeemState = { ok: boolean; amount?: string; message?: string } | null;

const REASONS: Record<string, string> = {
  not_found: "That code isn't right. Check it and try again.",
  void: "That gift card has been cancelled.",
  already_redeemed: "That gift card has already been claimed.",
};

/**
 * Decision 110: a member redeems a gift code. The full amount becomes gift
 * credit on their account, applied at checkout before any payment.
 */
export async function redeemGift(_prev: RedeemState, fd: FormData): Promise<RedeemState> {
  const code = String(fd.get("code") ?? "").trim();
  if (!code) return { ok: false, message: "Enter your gift code." };
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const supabase = createClient();
  const { data, error } = await supabase.rpc("gift_card_redeem", { p_code: code });
  if (error) {
    if (/PT403/.test(error.message)) return { ok: false, message: "That gift card is for a different studio." };
    return { ok: false, message: "That didn't work — please try again." };
  }
  const r = data as { ok: boolean; reason?: string; amount?: string } | null;
  if (!r?.ok) return { ok: false, message: REASONS[r?.reason ?? ""] ?? "That code could not be redeemed." };
  return { ok: true, amount: r.amount };
}
