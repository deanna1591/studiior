"use server";

import { createServerClient } from "@supabase/ssr";
import { currentSlug, currentMemberOrigin } from "@/lib/tenant";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createSession, CHANNELS_WITHOUT_APPLE_PAY } from "@/lib/xendit";
import { PHONE_INVALID } from "@/lib/phone";
import type { Database } from "@/lib/database.types";
import type { CodePreview } from "@/lib/discount-code";

export type GuestBuyState = { ok: boolean; url?: string; message?: string } | null;

function anonClient() {
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
}

/**
 * Decision 118: somebody without an account buys a plan. plan_buy_begin (the
 * fifteenth public function) checks the plan, fixes the price, rate-limits and
 * writes only the pending purchase; it hands this server the studio's encrypted
 * Xendit key, decrypted HERE and never in the browser, so we can open the
 * checkout. The browser receives only the checkout link. The webhook holds the
 * plan under the email (or attaches it to an existing account).
 */
export async function buyPlanAsGuest(_prev: GuestBuyState, fd: FormData): Promise<GuestBuyState> {
  const slug = currentSlug();
  const origin = currentMemberOrigin();
  if (!slug || !origin) return { ok: false, message: "Could not work out the studio address." };

  const planId = String(fd.get("plan_id") ?? "");
  const name = String(fd.get("name") ?? "").trim();
  const email = String(fd.get("email") ?? "").trim();
  const phone = String(fd.get("phone") ?? "").trim();
  if (!name) return { ok: false, message: "Please add your name." };
  if (!email.includes("@")) return { ok: false, message: "Please add your email address." };
  if (!phone) return { ok: false, message: PHONE_INVALID };

  const sb = anonClient();
  const { data: s } = await sb.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(s) ? s[0] : s;
  if (!studio) return { ok: false, message: "This studio could not be found." };

  const codeText = String(fd.get("code") ?? "").trim() || null;
  const { data: begun, error } = await sb.rpc("plan_buy_begin", {
    p_studio_id: studio.id, p_plan_id: planId,
    p_buyer_name: name, p_buyer_email: email, p_buyer_phone: phone,
    p_code: codeText as string,
  });
  const b = Array.isArray(begun) ? begun[0] : begun;
  if (error || !b) {
    const m = error?.message ?? "";
    const code = error?.code ?? "";
    if (code === "PT460") return { ok: false, message: m || "That code isn't valid." };
    if (code === "PT404") return { ok: false, message: "That plan isn't on sale right now." };
    if (code === "PT429") return { ok: false, message: "Too many right now. Try again in a minute." };
    if (code === "PT422" && /mobile/.test(m)) return { ok: false, message: PHONE_INVALID };
    if (code === "PT422" && /email/.test(m)) return { ok: false, message: "Please check your email address." };
    if (code === "PT422") return { ok: false, message: "Please check your name, email and mobile number." };
    if (code === "PT409" && /full/.test(m)) return { ok: false, message: "This plan is full. Ask the studio." };
    if (code === "PT409") return { ok: false, message: "This studio isn't set up for online payments yet." };
    return { ok: false, message: "Could not start the purchase. Please try again." };
  }

  let secret: string;
  try {
    secret = decryptSecret(b.secret_key_ciphertext as string);
  } catch {
    return { ok: false, message: "This studio's online payments aren't available right now." };
  }

  const res = await createSession(secret, {
    referenceId: b.purchase_id,
    amountCents: b.amount_cents,
    currency: b.currency,
    country: "PH",
    description: `${studio.name} · ${b.plan_name}`,
    customerReferenceId: b.purchase_id,
    customerGivenNames: name,
    customerEmail: email,
    metadata: { purchase_id: b.purchase_id, studio_id: studio.id, kind: "plan_guest" },
    ...(b.apple_pay_verified ? {} : { allowedChannels: CHANNELS_WITHOUT_APPLE_PAY }),
    successUrl: `${origin}/buy/${planId}/paid`,
    cancelUrl: `${origin}/buy/${planId}`,
  });
  if (!res.ok) return { ok: false, message: `Couldn't open checkout: ${res.error.message}` };
  return { ok: true, url: res.data.payment_link_url };
}

/**
 * Decision 120: check a code on /buy without an account. plan_buy_begin in
 * preview mode returns the price and writes no purchase (no new public
 * function). The email, when typed, lets a shared code apply once per person.
 */
export async function previewGuestCode(input: { planId: string; code: string; email?: string }): Promise<CodePreview> {
  const slug = currentSlug();
  const none: CodePreview = { ok: false, applied: false, code: null, listCents: null, priceCents: null,
    discountCents: 0, currency: null, message: "That code couldn't be checked. Try again." };
  if (!slug) return none;
  const sb = anonClient();
  const { data: s } = await sb.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(s) ? s[0] : s;
  if (!studio) return none;
  const { data, error } = await sb.rpc("plan_buy_begin", {
    p_studio_id: studio.id, p_plan_id: input.planId,
    p_buyer_email: (input.email?.trim() || null) as string,
    p_code: input.code, p_preview: true,
  });
  const r = Array.isArray(data) ? data[0] : data;
  if (error || !r) return none;
  const applied = r.code_applied === true;
  return {
    ok: applied || (r.code_message ?? "").startsWith("The sale price"),
    applied,
    code: r.code ?? null,
    listCents: r.list_cents ?? null,
    priceCents: applied ? r.amount_cents : null,
    discountCents: applied ? (r.discount_cents ?? 0) : 0,
    currency: r.currency ?? null,
    message: r.code_message ?? null,
  };
}
