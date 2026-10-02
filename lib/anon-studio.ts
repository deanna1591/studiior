import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";

export type AnonStudio = Database["public"]["Functions"]["studio_by_slug"]["Returns"][number];

/**
 * The studio for the CURRENT member host, resolved through studio_by_slug on a
 * cookie-less anon client — the one pre-login lookup (migration 004), the same
 * call the login page and the member layout make. Used by the PWA routes
 * (icon / manifest / install), which are all public and have no session. Null
 * when there is no slug or the slug is unknown/inactive.
 */
export async function anonStudio(): Promise<AnonStudio | null> {
  const slug = currentSlug();
  if (!slug) return null;
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(data) ? data[0] : data;
  return studio ?? null;
}
