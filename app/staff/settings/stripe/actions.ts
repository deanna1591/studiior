"use server";

import { redirect } from "next/navigation";
import { getStaffContext } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type ConnectState = { ok: boolean; message: string } | null;

/**
 * Start Connect OAuth.
 *
 * The state is minted in the database (single-use, thirty minutes) rather than
 * in a cookie: the callback is an unauthenticated GET arriving from Stripe, and
 * the state is the only thing tying it back to the studio that started it.
 * Owner-only is enforced in begin_stripe_connect(), not here — a check in a
 * server action is a promise, a check in the function is the rule.
 */
export async function beginConnect(_prev: ConnectState, _fd: FormData): Promise<ConnectState> {
  const ctx = await getStaffContext();
  if (!ctx) return { ok: false, message: "You are not signed in." };

  const clientId = process.env.STRIPE_CONNECT_CLIENT_ID;
  if (!clientId) {
    return { ok: false, message: "STRIPE_CONNECT_CLIENT_ID is not set on this server." };
  }

  const supabase = createClient();
  const { data: state, error } = await supabase.rpc("begin_stripe_connect", {
    p_studio_id: ctx.studioId,
  });
  if (error) {
    return /PT403/.test(error.message)
      ? { ok: false, message: "Only the studio owner can connect Stripe." }
      : { ok: false, message: error.message };
  }

  const url = new URL("https://connect.stripe.com/oauth/authorize");
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("scope", "read_write");
  url.searchParams.set("state", String(state));
  url.searchParams.set("redirect_uri",
    `${process.env.NEXT_PUBLIC_STAFF_ORIGIN ?? "http://localhost:3000"}/settings/stripe/callback`);
  redirect(url.toString());
}
