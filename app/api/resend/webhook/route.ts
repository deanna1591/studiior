import { NextRequest, NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";
import crypto from "node:crypto";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Resend delivery webhook (Decision 113).
 *
 * Resend signs its webhooks with Svix. We verify the signature HERE in Next with
 * the secret in RESEND_WEBHOOK_SECRET (never in the DB, never shipped to the
 * client), then insert the verified event into resend_webhook_inbox via the anon
 * client. There is NO service-role client and NO new anon RPC: the inbox has an
 * anon INSERT policy (a table, not a function, so the anon surface stays exactly
 * thirteen), and a service-context sweep applies each event — matching it to the
 * notification we sent by provider_message_id, so a forged insert is a no-op.
 *
 * The body is read as TEXT and the HMAC is over `{svix-id}.{svix-timestamp}.{body}`
 * exactly as Svix specifies.
 */
function verifySvix(secret: string, id: string, ts: string, sigHeader: string, body: string): boolean {
  const base64 = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  let secretBytes: Buffer;
  try {
    secretBytes = Buffer.from(base64, "base64");
  } catch {
    return false;
  }
  const expected = crypto.createHmac("sha256", secretBytes).update(`${id}.${ts}.${body}`).digest("base64");
  const expectedBuf = Buffer.from(expected);
  // The header is space-separated "v1,<signature>" entries; match any.
  return sigHeader.split(" ").some((part) => {
    const comma = part.indexOf(",");
    const sig = comma >= 0 ? part.slice(comma + 1) : part;
    const sigBuf = Buffer.from(sig);
    return sigBuf.length === expectedBuf.length && crypto.timingSafeEqual(sigBuf, expectedBuf);
  });
}

export async function POST(request: NextRequest) {
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (!secret) {
    // Not configured on this deployment; accept-and-ignore so Resend stops retrying.
    return NextResponse.json({ ok: true, ignored: "not configured" });
  }

  const id = request.headers.get("svix-id");
  const ts = request.headers.get("svix-timestamp");
  const sig = request.headers.get("svix-signature");
  if (!id || !ts || !sig) {
    return NextResponse.json({ error: "missing signature headers" }, { status: 400 });
  }

  // Timestamp tolerance: reject anything more than five minutes out.
  const tsSec = Number(ts);
  if (!Number.isFinite(tsSec) || Math.abs(Date.now() / 1000 - tsSec) > 300) {
    return NextResponse.json({ error: "stale timestamp" }, { status: 400 });
  }

  const body = await request.text();
  if (!verifySvix(secret, id, ts, sig, body)) {
    return NextResponse.json({ error: "bad signature" }, { status: 400 });
  }

  let event: { type?: string; data?: { email_id?: string; to?: string | string[] } };
  try {
    event = JSON.parse(body);
  } catch {
    return NextResponse.json({ error: "bad json" }, { status: 400 });
  }

  const type = event.type ?? "";
  if (!["email.delivered", "email.bounced", "email.complained"].includes(type)) {
    return NextResponse.json({ ok: true, ignored: type }); // other event types: nothing to do
  }

  const to = event.data?.to;
  const email = Array.isArray(to) ? to[0] ?? null : to ?? null;

  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );

  const { error } = await supabase.from("resend_webhook_inbox").insert({
    event_type: type,
    provider_message_id: event.data?.email_id ?? null,
    email,
    raw: event as unknown as Database["public"]["Tables"]["resend_webhook_inbox"]["Insert"]["raw"],
  });
  if (error) {
    return NextResponse.json({ error: "store failed" }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
