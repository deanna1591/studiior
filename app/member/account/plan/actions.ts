"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMemberOrigin } from "@/lib/tenant";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createSession, getCustomerByReferenceId } from "@/lib/xendit";

export type BuyState = { ok: boolean; url?: string; message?: string } | null;

/**
 * Decision 40: buy a one-time plan (pack / drop-in) through Xendit.
 *
 * The amount is set FROM THE PLAN in xendit_begin_purchase (never trusted from
 * the client). The studio's secret key is decrypted in THIS server runtime from
 * the ciphertext xendit_checkout_context hands back — the browser never sees it.
 * On success we return the hosted-checkout URL and the client navigates there
 * (a full external navigation, not a server redirect to a member path).
 */
export async function buyPlan(_prev: BuyState, fd: FormData): Promise<BuyState> {
  const planId = String(fd.get("plan_id") ?? "").trim();
  if (!planId) return { ok: false, message: "No plan chosen." };

  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const origin = currentMemberOrigin();
  if (!origin) return { ok: false, message: "Could not work out the studio address." };

  const supabase = createClient();

  const { data: begun, error: beginErr } = await supabase.rpc("xendit_begin_purchase", {
    p_studio_id: ctx.studioId,
    p_plan_id: planId,
  });
  const purchase = Array.isArray(begun) ? begun[0] : begun;
  if (beginErr || !purchase) {
    const m = beginErr?.message ?? "";
    if (/PT422/.test(m)) return { ok: false, message: "That plan can’t be bought online." };
    if (/PT409/.test(m)) return { ok: false, message: "This studio isn’t set up for online payments yet." };
    if (/PT404/.test(m)) return { ok: false, message: "That plan is no longer on sale." };
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

  const [{ data: plan }, { data: member }, { data: cust }] = await Promise.all([
    supabase.from("membership_plans").select("name").eq("id", planId).maybeSingle(),
    // Xendit requires a customer.reference_id + given_names; the member reads
    // their own row (members_self RLS).
    supabase.from("members").select("first_name, last_name, email").eq("id", ctx.memberId).maybeSingle(),
    // A Xendit customer created on a prior checkout — reused as customer_id so
    // we do not re-send the reference_id (which Xendit refuses the second time).
    supabase.from("member_payment_customers").select("customer_ref")
      .eq("member_id", ctx.memberId).eq("provider", "xendit").maybeSingle(),
  ]);

  // Must match buildSessionBody's stripping, so the /customers lookup uses the
  // same reference_id we would have created the customer with.
  const strippedRef = ctx.memberId.replace(/[^a-zA-Z0-9]/g, "");
  const common = {
    referenceId: purchase.purchase_id,
    amountCents: purchase.amount_cents,
    currency: purchase.currency,
    country: "PH",
    description: `${ctx.studioName} — ${plan?.name ?? "plan"}`,
    // purchase_id is the primary way the callback resolves back to this purchase.
    metadata: { purchase_id: purchase.purchase_id, studio_id: ctx.studioId, member_id: ctx.memberId, kind: "plan", plan_id: planId },
    successUrl: `${origin}/purchase/${purchase.purchase_id}`,
    cancelUrl: `${origin}/account/plan`,
  };
  const withCustomerId = (customerId: string) => createSession(secret, { ...common, customerId });
  const withCustomerObject = () => createSession(secret, {
    ...common,
    customerReferenceId: ctx.memberId, // hyphens stripped in buildSessionBody
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
      // We created the customer on a prior checkout but did not store its id;
      // look it up by reference_id and retry once with customer_id.
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
