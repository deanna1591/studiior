"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMemberOrigin } from "@/lib/tenant";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createSession, getCustomerByReferenceId } from "@/lib/xendit";

export type BuyState = { ok: boolean; url?: string; message?: string } | null;

/**
 * Decision 63b: buy a product through the SAME Xendit checkout a plan rides.
 *
 * The amount is set FROM THE PRODUCT in xendit_begin_product_purchase (never
 * trusted from the client), which also RESERVES stock so a second member cannot
 * buy the last unit while this one pays. The rest is byte-for-byte buyPlan: the
 * studio secret is decrypted in this runtime, the hosted-checkout URL is
 * returned, and the client navigates there.
 */
export async function buyProduct(_prev: BuyState, fd: FormData): Promise<BuyState> {
  const productId = String(fd.get("product_id") ?? "").trim();
  const quantity = Math.max(1, Math.min(99, Number(fd.get("quantity") ?? 1) || 1));
  if (!productId) return { ok: false, message: "No product chosen." };

  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const origin = currentMemberOrigin();
  if (!origin) return { ok: false, message: "Could not work out the studio address." };

  const supabase = createClient();

  const { data: begun, error: beginErr } = await supabase.rpc("xendit_begin_product_purchase", {
    p_studio_id: ctx.studioId,
    p_product_id: productId,
    p_quantity: quantity,
  });
  const purchase = Array.isArray(begun) ? begun[0] : begun;
  if (beginErr || !purchase) {
    const m = beginErr?.message ?? "";
    if (/Only \d+ left/i.test(m)) return { ok: false, message: m.replace(/^.*?(Only \d+ left\.).*$/, "$1") };
    if (/PT409/.test(m)) return { ok: false, message: "That isn’t available to buy online right now." };
    if (/PT404/.test(m)) return { ok: false, message: "That product is no longer on sale." };
    if (/PT400/.test(m)) return { ok: false, message: "Choose how many." };
    return { ok: false, message: m || "Could not start the purchase." };
  }

  const { data: cctx, error: cErr } = await supabase.rpc("xendit_checkout_context", {
    p_studio_id: ctx.studioId,
  });
  const c = Array.isArray(cctx) ? cctx[0] : cctx;
  if (cErr || !c) return { ok: false, message: "The studio’s online payments aren’t available right now." };

  let secret: string;
  try {
    secret = decryptSecret(c.secret_key_ciphertext);
  } catch {
    return { ok: false, message: "The studio’s payment key couldn’t be read — ask the studio to reconnect Xendit." };
  }

  const [{ data: product }, { data: member }, { data: cust }] = await Promise.all([
    supabase.from("products").select("name").eq("id", productId).maybeSingle(),
    supabase.from("members").select("first_name, last_name, email").eq("id", ctx.memberId).maybeSingle(),
    supabase.from("member_payment_customers").select("customer_ref")
      .eq("member_id", ctx.memberId).eq("provider", "xendit").maybeSingle(),
  ]);

  const strippedRef = ctx.memberId.replace(/[^a-zA-Z0-9]/g, "");
  const common = {
    referenceId: purchase.purchase_id,
    amountCents: purchase.amount_cents,
    currency: purchase.currency,
    country: "PH",
    description: `${ctx.studioName} — ${product?.name ?? "item"}`,
    metadata: { purchase_id: purchase.purchase_id, studio_id: ctx.studioId, member_id: ctx.memberId, kind: "product", product_id: productId },
    successUrl: `${origin}/purchase/${purchase.purchase_id}`,
    cancelUrl: `${origin}/shop`,
  };
  const withCustomerId = (customerId: string) => createSession(secret, { ...common, customerId });
  const withCustomerObject = () => createSession(secret, {
    ...common,
    customerReferenceId: ctx.memberId,
    customerGivenNames: member?.first_name ?? ctx.firstName ?? "Member",
    customerSurname: member?.last_name ?? undefined,
    customerEmail: member?.email ?? undefined,
  });

  let res: Awaited<ReturnType<typeof createSession>>;
  let newCustomerId: string | null = null;
  if (cust?.customer_ref) {
    res = await withCustomerId(cust.customer_ref);
  } else {
    res = await withCustomerObject();
    if (res.ok) {
      newCustomerId = res.data.customer_id ?? null;
    } else if (/reference_id.*used before|has been used before/i.test(res.error.message)) {
      const found = await getCustomerByReferenceId(secret, strippedRef);
      if (found) {
        await supabase.rpc("xendit_set_customer", { p_studio_id: ctx.studioId, p_customer_id: found });
        res = await withCustomerId(found);
      }
    }
  }

  if (!res.ok) {
    return { ok: false, message: `Couldn’t open checkout: ${res.error.message}` };
  }
  if (newCustomerId) {
    await supabase.rpc("xendit_set_customer", { p_studio_id: ctx.studioId, p_customer_id: newCustomerId });
  }

  await supabase.rpc("xendit_attach_session", {
    p_purchase_id: purchase.purchase_id,
    p_session_id: res.data.payment_session_id,
    p_link_url: res.data.payment_link_url,
  });

  return { ok: true, url: res.data.payment_link_url };
}
