"use server";

import { getMemberContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMemberOrigin } from "@/lib/tenant";
import { decryptSecret } from "@/lib/integrations-crypto";
import { createSession, getCustomerByReferenceId } from "@/lib/xendit";
import { safeNext } from "@/lib/auth-redirect";

export type BuyState = { ok: boolean; url?: string; message?: string } | null;

type MemberCtx = NonNullable<Awaited<ReturnType<typeof getMemberContext>>>;

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

  // Decision 73b: where to land after a successful purchase (the class the
  // member was paying for). safeNext keeps it a relative path — no open redirect.
  const rawReturn = fd.get("return");
  const returnTo = rawReturn ? safeNext(String(rawReturn)) : "/";

  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  return beginXenditCheckout(ctx, planId, returnTo);
}

/**
 * Decision 88 slice A: the ONE Xendit-session creation, shared by buyPlan (the
 * plans page) and the checkout screen's "Continue to pay". This is a pure
 * extraction of what buyPlan already did — no new money logic — so a checkout
 * purchase and a plans-page purchase open the identical hosted session, snapshot
 * the amount from the plan the same way, and reuse the same Xendit customer.
 * On activation the unchanged apply_plan_to_unpaid settles any held drop-in.
 */
export async function beginXenditCheckout(
  ctx: MemberCtx, planId: string, returnTo: string,
): Promise<BuyState> {
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

  const { data: plan } = await supabase.from("membership_plans")
    .select("name").eq("id", planId).maybeSingle();

  return openXenditSession(ctx, {
    purchaseId: purchase.purchase_id,
    amountCents: purchase.amount_cents,
    currency: purchase.currency,
    description: `${ctx.studioName} — ${plan?.name ?? "plan"}`,
    metadata: { purchase_id: purchase.purchase_id, studio_id: ctx.studioId, member_id: ctx.memberId, kind: "plan", plan_id: planId },
    successUrl: `${origin}/purchase/${purchase.purchase_id}${returnTo && returnTo !== "/" ? `?return=${encodeURIComponent(returnTo)}` : ""}`,
    cancelUrl: `${origin}/account/plan`,
  });
}

/**
 * The ONE Xendit-session creation for a purchase that already exists (the SQL
 * begin function snapshotted the amount). Decrypts the studio secret in this
 * runtime, creates the hosted session (reusing the member's Xendit customer),
 * attaches it, and returns the hosted-checkout URL. Shared by the plan checkout
 * (beginXenditCheckout) and the Decision 103 reservation checkout.
 */
async function openXenditSession(
  ctx: MemberCtx,
  opts: {
    purchaseId: string; amountCents: number; currency: string; description: string;
    metadata: Record<string, string>; successUrl: string; cancelUrl: string;
  },
): Promise<BuyState> {
  const supabase = createClient();
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

  const [{ data: member }, { data: cust }] = await Promise.all([
    supabase.from("members").select("first_name, last_name, email").eq("id", ctx.memberId).maybeSingle(),
    supabase.from("member_payment_customers").select("customer_ref")
      .eq("member_id", ctx.memberId).eq("provider", "xendit").maybeSingle(),
  ]);

  const strippedRef = ctx.memberId.replace(/[^a-zA-Z0-9]/g, "");
  const common = {
    referenceId: opts.purchaseId,
    amountCents: opts.amountCents,
    currency: opts.currency,
    country: "PH",
    description: opts.description,
    metadata: opts.metadata,
    successUrl: opts.successUrl,
    cancelUrl: opts.cancelUrl,
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
    p_purchase_id: opts.purchaseId,
    p_session_id: res.data.payment_session_id,
    p_link_url: res.data.payment_link_url,
  });

  return { ok: true, url: res.data.payment_link_url };
}

/**
 * Decision 103: hold a free-first seat and take the reservation fee. reserve_free_first
 * holds the seat as pending_payment (the drop-in window), xendit_begin_reservation
 * creates the fee purchase, and the webhook completes the comp free seat
 * (book_first_free_run). On return the member lands on the class page, which shows
 * one of the three states.
 */
export async function startReservation(occId: string): Promise<BuyState> {
  if (!occId) return { ok: false, message: "No class chosen." };
  const ctx = await getMemberContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  const origin = currentMemberOrigin();
  if (!origin) return { ok: false, message: "Could not work out the studio address." };

  const supabase = createClient();

  // Decision 103 hotfix: an EXISTING free booking (the member already holds their
  // free class and got a "pay to keep your spot" due) goes straight to the fee
  // checkout. reserve_free_first is only for a brand-new first-timer — running it
  // here would check eligibility against the member's own comp booking and refuse
  // "already_had_free". We reuse the existing seat; the fee makes it reserved.
  let bookingId: string | null = null;
  const { data: existing } = await supabase.from("bookings")
    .select("id")
    .eq("occurrence_id", occId)
    .eq("member_id", ctx.memberId)
    .eq("payment_source", "comp")
    .in("status", ["booked", "pending_payment"])
    .limit(1);
  bookingId = existing?.[0]?.id ?? null;

  if (!bookingId) {
    // A brand-new first-timer: hold a comp seat through the eligibility gate.
    const { data: held, error: hErr } = await supabase.rpc("reserve_free_first", { p_occurrence_id: occId });
    if (hErr) return { ok: false, message: hErr.message };
    const h = held as { ok: boolean; reason?: string; booking_id?: string } | null;
    if (!h?.ok || !h.booking_id) {
      return { ok: false, message: FREE_RESERVE_REASONS[h?.reason ?? ""] ?? "That didn’t work — please try again." };
    }
    bookingId = h.booking_id;
  }

  const { data: begun, error: bErr } = await supabase.rpc("xendit_begin_reservation", {
    p_studio_id: ctx.studioId, p_booking_id: bookingId,
  });
  const purchase = Array.isArray(begun) ? begun[0] : begun;
  if (bErr || !purchase) return { ok: false, message: bErr?.message || "Could not start the reservation." };

  return openXenditSession(ctx, {
    purchaseId: purchase.purchase_id,
    amountCents: purchase.amount_cents,
    currency: purchase.currency,
    description: `${ctx.studioName} — reservation fee`,
    metadata: { purchase_id: purchase.purchase_id, studio_id: ctx.studioId, member_id: ctx.memberId, kind: "reservation", booking_id: bookingId },
    successUrl: `${origin}/class/${occId}?reserved=1`,
    cancelUrl: `${origin}/class/${occId}`,
  });
}

const FREE_RESERVE_REASONS: Record<string, string> = {
  no_reservation_fee: "This class does not need a reservation fee.",
  not_authorised: "You are not signed in.",
  not_found: "That class could not be found.",
  class_not_bookable: "That class is not open for booking.",
  class_in_past: "That class has already started.",
  class_full: "That class is full.",
  not_first: "Your free first class has already been used.",
  already_had_free: "Your free first class has already been used.",
  already_member: "This looks like an existing account.",
  missed: "Your free class was used when you missed it.",
  late_cancel: "Your free class was used.",
  duplicate: "Your free first class has already been used.",
  not_staffed_yet: "This class isn’t open for booking yet.",
  class_hidden: "That class isn’t available.",
  past_booking_cutoff: "Booking has closed for that class.",
  outside_booking_window: "That class isn’t open for booking yet.",
  free_first_closed_here: "This class isn’t open to first-timers.",
  flex_not_allowed: "Free classes are on core classes only here.",
  not_trial_class: "This class isn’t open to first-timers.",
  free_seats_full: "The free spots for this class are taken.",
  peak_not_allowed: "Free classes aren’t available at peak times.",
  month_not_published: "That class isn’t open for booking yet.",
};
