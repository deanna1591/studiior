"use server";

import { createServerClient } from "@supabase/ssr";
import { currentSlug, currentMemberOrigin } from "@/lib/tenant";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createSession, CHANNELS_WITHOUT_APPLE_PAY } from "@/lib/xendit";
import { giftAmountProblem } from "@/lib/gift-card";
import type { Database } from "@/lib/database.types";

export type GiftState = { ok: boolean; url?: string; message?: string } | null;

function anonClient() {
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
}

/**
 * Decision 110: a logged-out visitor buys a gift card. gift_card_begin (the
 * fourteenth anon surface) validates the amount and rate-limits, writes only the
 * pending rows, and hands back the secret ciphertext — decrypted in THIS server
 * runtime, never the browser — so we can open the Xendit session. The webhook
 * issues the card on payment. No session is attached (the buyer has no account,
 * so there is no return-check belt; the webhook is the path).
 */
export async function buyGift(_prev: GiftState, fd: FormData): Promise<GiftState> {
  const slug = currentSlug();
  const origin = currentMemberOrigin();
  if (!slug || !origin) return { ok: false, message: "Could not work out the studio address." };

  const amountCents = Math.round(Number(fd.get("amount_cents")) || 0);
  const buyerName = String(fd.get("buyer_name") ?? "").trim();
  const buyerEmail = String(fd.get("buyer_email") ?? "").trim();
  const recipientName = String(fd.get("recipient_name") ?? "").trim();
  const recipientEmail = String(fd.get("recipient_email") ?? "").trim();
  const message = String(fd.get("message") ?? "").trim();
  const deliveryRaw = String(fd.get("delivery_date") ?? "").trim();
  const deliveryDate = deliveryRaw || null;

  if (!amountCents) return { ok: false, message: "Choose an amount." };
  const amountProblem = giftAmountProblem(amountCents);
  if (amountProblem) return { ok: false, message: amountProblem };
  if (!buyerEmail.includes("@") || !recipientEmail.includes("@")) {
    return { ok: false, message: "A buyer and a recipient email are needed." };
  }

  const sb = anonClient();
  const { data: s } = await sb.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(s) ? s[0] : s;
  if (!studio) return { ok: false, message: "This studio could not be found." };

  const { data: begun, error } = await sb.rpc("gift_card_begin", {
    p_studio_id: studio.id,
    p_amount_cents: amountCents,
    p_buyer_name: buyerName || undefined,
    p_buyer_email: buyerEmail,
    p_recipient_name: recipientName || undefined,
    p_recipient_email: recipientEmail,
    p_message: message || undefined,
    p_delivery_date: deliveryDate ?? undefined,
  });
  const g = Array.isArray(begun) ? begun[0] : begun;
  if (error || !g) {
    const m = error?.message ?? "";
    if (/PT404/.test(m)) return { ok: false, message: "Gift cards aren't available for this studio." };
    if (/PT409/.test(m)) return { ok: false, message: "This studio isn't set up for online payments yet." };
    if (/PT429/.test(m)) return { ok: false, message: "Too many right now — try again in a minute." };
    if (/PT422/.test(m)) return { ok: false, message: "Check the amount, the emails, and the delivery date." };
    return { ok: false, message: m || "Could not start the purchase." };
  }

  let secret: string;
  try {
    secret = decryptSecret(g.secret_key_ciphertext);
  } catch {
    return { ok: false, message: "This studio's online payments aren't available right now." };
  }

  const res = await createSession(secret, {
    referenceId: g.purchase_id,
    amountCents: g.amount_cents,
    currency: g.currency,
    country: "PH",
    description: `${studio.name} — gift card`,
    customerReferenceId: g.purchase_id,
    customerGivenNames: buyerName || "Gift buyer",
    customerEmail: buyerEmail,
    metadata: { purchase_id: g.purchase_id, studio_id: studio.id, kind: "gift" },
    // Decision 110(a): offer Apple Pay only once the studio has it verified.
    ...(g.apple_pay_verified ? {} : { allowedChannels: CHANNELS_WITHOUT_APPLE_PAY }),
    successUrl: `${origin}/gift/thanks`,
    cancelUrl: `${origin}/gift`,
  });
  if (!res.ok) return { ok: false, message: `Couldn't open checkout: ${res.error.message}` };
  return { ok: true, url: res.data.payment_link_url };
}
