import { NextRequest, NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * The Connect webhook.
 *
 * This route does as little as possible on purpose. It does NOT verify the
 * signature, look up a tenant, or decide anything — it hands the raw body and
 * the signature header to stripe_webhook(), which recomputes the HMAC in the
 * database before it reads a single field.
 *
 * That is why there is no service-role client here. A webhook has no session
 * and RLS cannot express "Stripe said so", so the choice was between a key that
 * can do anything to any tenant and a function that will not act without a
 * valid signature. The signature is the credential.
 *
 * The body must be read as TEXT and passed through unchanged: the HMAC is over
 * the exact bytes Stripe sent, and JSON.parse followed by JSON.stringify would
 * reorder keys and invalidate it.
 */
export async function POST(request: NextRequest) {
  const signature = request.headers.get("stripe-signature");
  if (!signature) {
    return NextResponse.json({ error: "no signature" }, { status: 400 });
  }

  const payload = await request.text();

  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );

  const { data, error } = await supabase.rpc("stripe_webhook", {
    p_payload: payload,
    p_signature: signature,
  });

  if (error) {
    // 401 for a bad signature, 503 for a missing secret: Stripe retries a 5xx
    // for days and gives up on a 4xx, which is the behaviour we want in each
    // case. A forged delivery should not be retried; a misconfigured server
    // should be, because the event is real and we will want it once fixed.
    const status = /PT401|bad Stripe signature/.test(error.message) ? 401
                 : /PT503|not configured/.test(error.message) ? 503
                 : 400;
    console.error("stripe webhook refused:", error.message);
    return NextResponse.json({ error: error.message }, { status });
  }

  // Everything else is a 200, including 'duplicate' and 'unknown_account'.
  // Both are things Stripe cannot fix by sending it again, and a non-2xx would
  // buy us days of pointless retries.
  return NextResponse.json(data ?? { status: "ok" });
}
