import { tenantStore } from "@/lib/store-verify";
import { parseFingerprints, assetlinksFor } from "@/lib/well-known";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 52a — Android Digital Asset Links, per tenant, on the member host.
 * 404 until the studio has an android_package + at least one SHA-256. Public:
 * no session, no cookies, no redirect; application/json, cached 5 minutes.
 */
export async function GET(req: Request) {
  const t = await tenantStore(req);
  if (!t) return new Response("Not found", { status: 404 });
  const body = assetlinksFor({
    androidPackage: t.androidPackage,
    fingerprints: parseFingerprints(t.fingerprints ?? "").valid,
  });
  if (!body) return new Response("Not found", { status: 404 });
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" },
  });
}
