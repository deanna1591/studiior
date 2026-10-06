import { createServerClient } from "@supabase/ssr";
import { resolveHost } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";

/**
 * Decision 52a — resolve the requesting member host to its tenant's store
 * identifiers, for the public /.well-known route handlers. Returns null for a
 * non-member host or an unknown slug (the handler then 404s). Reads through the
 * anon studio_by_slug (one of the thirteen) — no session, no cookies, no new
 * anon surface.
 */
export async function tenantStore(req: Request): Promise<
  { androidPackage: string | null; fingerprints: string | null; teamId: string | null; bundleId: string | null }
  | null
> {
  const h = req.headers;
  const host = h.get("x-forwarded-host") ?? h.get("host") ?? "";
  const { app, slug } = resolveHost(host);
  if (app !== "member" || !slug) return null;

  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug });
  const s = (Array.isArray(data) ? data[0] : data) as
    | { android_package: string | null; android_sha256_fingerprints: string | null;
        ios_team_id: string | null; ios_bundle_id: string | null } | null;
  if (!s) return null;
  return {
    androidPackage: s.android_package ?? null,
    fingerprints: s.android_sha256_fingerprints ?? null,
    teamId: s.ios_team_id ?? null,
    bundleId: s.ios_bundle_id ?? null,
  };
}
