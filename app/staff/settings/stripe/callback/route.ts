import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { stripe } from "@/lib/stripe";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Where Stripe sends the owner back.
 *
 * Exchanges the one-time code for the connected account id, then hands both the
 * state and the account id to complete_stripe_connect(), which re-checks that
 * the caller is the owner. Re-checked here rather than trusted from the start of
 * the flow: this is a fresh request, and whoever is holding the state is not
 * necessarily whoever minted it.
 */
export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const back = (msg: string) =>
    NextResponse.redirect(new URL(`/settings/stripe?e=${encodeURIComponent(msg)}`, request.url));

  if (params.get("error")) {
    return back(params.get("error_description") ?? "Stripe cancelled the connection.");
  }
  const code = params.get("code");
  const state = params.get("state");
  if (!code || !state) return back("That link was incomplete. Start again.");

  let accountId: string;
  try {
    const token = await stripe().oauth.token({ grant_type: "authorization_code", code });
    if (!token.stripe_user_id) return back("Stripe did not return an account id.");
    accountId = token.stripe_user_id;
  } catch (e) {
    return back(e instanceof Error ? e.message : "Stripe refused the connection.");
  }

  const supabase = createClient();
  const { error } = await supabase.rpc("complete_stripe_connect", {
    p_state: state,
    p_account_id: accountId,
  });
  if (error) {
    return back(/PT403/.test(error.message)
      ? "Only the studio owner can connect Stripe."
      : error.message);
  }

  return NextResponse.redirect(new URL("/settings/stripe?connected=1", request.url));
}
