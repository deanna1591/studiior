import { headers } from "next/headers";
import type { createClient } from "@/lib/supabase/server";
import { resolveMemberBase, memberOriginFrom } from "@/lib/member-urls";

/**
 * Decision 57 follow-up — the member origin (https://{slug}.{member_app_domain})
 * for a link built on the STAFF side, where the request host is app.studiior.com
 * (not a member host) and the env var may be unset. Resolves the base from the
 * DB source of truth (member_app_domain(), what the SQL email links use), then
 * the env var, then the request host (never localhost on a non-local request).
 */
export async function staffMemberOrigin(
  supabase: ReturnType<typeof createClient>,
  slug: string,
): Promise<string> {
  const { data } = await supabase.rpc("member_app_domain");
  const base = resolveMemberBase(
    data ?? null,
    process.env.NEXT_PUBLIC_MEMBER_DOMAIN ?? null,
    headers().get("host"),
  );
  return memberOriginFrom(base, slug);
}
