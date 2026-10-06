import { tenantStore } from "@/lib/store-verify";
import { aasaFor } from "@/lib/well-known";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Decision 52a — Apple App Site Association, per tenant, on the member host.
 * Served at /.well-known/apple-app-site-association (NO extension),
 * application/json, no redirect. 404 until the studio has a Team ID + bundle id.
 */
export async function GET(req: Request) {
  const t = await tenantStore(req);
  if (!t) return new Response("Not found", { status: 404 });
  const body = aasaFor({ teamId: t.teamId, bundleId: t.bundleId });
  if (!body) return new Response("Not found", { status: 404 });
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" },
  });
}
