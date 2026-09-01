"use server";

import { redirect } from "next/navigation";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { stripe } from "@/lib/stripe";

export type BillingState = { ok: boolean; message: string } | null;

/**
 * Start a subscription to Studiior, on OUR account.
 *
 * Deliberately `stripe()` and not `stripeFor()`: this is the one place in the
 * codebase where money comes to us rather than to a studio, so there is no
 * connected account and no `stripeAccount` header. Getting that wrong would
 * bill the studio's own customers for our software.
 *
 * There is no manual alternative here on purpose. A studio may take cash from
 * its own members all day (Decision 16) and still pays us by card: we are not
 * going to chase bank transfers from ten studios, and building a dunning
 * process for our own invoices is not the product.
 */
export async function startPlatformCheckout(
  _prev: BillingState, _fd: FormData,
): Promise<BillingState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };
  if (ctx.role !== "owner") {
    return { ok: false, message: "Only the studio owner can set up billing." };
  }

  const priceId = process.env.STRIPE_PLATFORM_PRICE_ID;
  if (!priceId) {
    return { ok: false, message: "STRIPE_PLATFORM_PRICE_ID is not set on this server." };
  }

  const origin = process.env.NEXT_PUBLIC_STAFF_ORIGIN ?? "http://localhost:3000";
  let url: string | null = null;

  try {
    const supabase = createClient();
    const { data: sub } = await supabase
      .from("platform_subscriptions")
      .select("stripe_customer_id").eq("studio_id", ctx.studioId).maybeSingle();

    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      customer: sub?.stripe_customer_id ?? undefined,
      customer_email: sub?.stripe_customer_id ? undefined : ctx.email ?? undefined,
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${origin}/billing?paid=1`,
      cancel_url: `${origin}/billing?cancelled=1`,
      // The webhook resolves the studio from our own customer id where it can,
      // and from this where it cannot — both are ours, because this is our
      // account rather than a connected one.
      metadata: { studio_id: ctx.studioId },
      subscription_data: { metadata: { studio_id: ctx.studioId } },
    });
    url = session.url;
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : "Stripe refused that." };
  }

  if (!url) return { ok: false, message: "Stripe did not return a checkout link." };
  redirect(url);
}
