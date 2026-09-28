import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Xendit callback (Decision 40). Xendit POSTs payment.succeeded / payment.failure
 * here with an `x-callback-token` header. This route is a THIN pass-through: it
 * hands the parsed payload and the token to xendit_webhook (SECURITY DEFINER,
 * anon), which resolves the tenant from OUR reference_id, verifies the token
 * against that studio's stored hash IN SQL, stores the event idempotently and
 * activates the purchase. All trust decisions are in the function — the token
 * is the credential and it is verified there, not here, so a direct call to the
 * anon RPC cannot bypass it (the stripe_webhook shape).
 *
 * No service-role client: an anon client calling an anon-granted function.
 */
export async function POST(request: NextRequest): Promise<NextResponse> {
  const token = request.headers.get("x-callback-token") ?? "";
  const raw = await request.text();

  let event: unknown;
  try {
    event = raw ? JSON.parse(raw) : null;
  } catch {
    return NextResponse.json({ error: "bad json" }, { status: 400 });
  }
  if (!event || typeof event !== "object") {
    return NextResponse.json({ error: "empty body" }, { status: 400 });
  }

  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );

  const { data, error } = await supabase.rpc("xendit_webhook", {
    p_event: event as Database["public"]["Functions"]["xendit_webhook"]["Args"]["p_event"],
    p_token: token,
  });

  if (error) {
    // A bad token is PT401 (nothing stored). supabase-js carries the Postgres
    // SQLSTATE in error.code (not always in the message), so check both.
    if (error.code === "PT401" || /PT401/.test(error.message)) {
      return NextResponse.json({ error: "invalid token" }, { status: 401 });
    }
    // Genuine server error: 500 so Xendit retries. NEVER echo the database
    // message to the caller — the real error goes only to the server logs.
    console.error("xendit callback failed", error);
    return NextResponse.json({ error: "callback failed" }, { status: 500 });
  }

  // ignored / duplicate / processed / refused all come back with no error -> 200
  // (a mismatch or a sample won't fix itself on a retry; Xendit stops retrying).
  return NextResponse.json(data ?? { result: "ok" }, { status: 200 });
}
