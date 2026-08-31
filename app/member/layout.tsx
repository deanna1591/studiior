import type { Metadata } from "next";
import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";

/**
 * The member app is the studio's, including its name in the browser tab.
 *
 * The root layout titles everything "Studiior", which is right for the staff
 * app and wrong here: the tab, the bookmark and the name iOS uses when someone
 * adds this to their home screen are all places a member looks, and none of
 * them should say the name of the company that sold their studio software.
 *
 * Resolved through studio_by_slug() on a cookie-less anon client — the same
 * pre-login lookup middleware uses (migration 004), and the only function anon
 * may execute. Metadata is generated before anyone is signed in, so it cannot
 * depend on a session.
 */
export async function generateMetadata(): Promise<Metadata> {
  const slug = currentSlug();
  if (!slug) return {};

  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug });
  const studio = Array.isArray(data) ? data[0] : data;
  if (!studio?.name) return {};

  return {
    title: studio.name,
    applicationName: studio.name,
    appleWebApp: { capable: true, title: studio.name, statusBarStyle: "default" },
  };
}

export default function MemberLayout({ children }: { children: React.ReactNode }) {
  return children;
}
