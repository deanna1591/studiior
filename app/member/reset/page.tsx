import Link from "next/link";
import { createServerClient } from "@supabase/ssr";
import { createClient } from "@/lib/supabase/server";
import { currentSlug } from "@/lib/tenant";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { Database } from "@/lib/database.types";
import ResetForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 84 — set a new password.
 *
 * Reached only from a recovery link, which /auth/callback has already turned
 * into a recovery SESSION. If there is no session the link was bad or has
 * expired (> 1 hour), so this shows the way to request a fresh one rather than
 * an input that cannot work. The role carried through the link (?role=) decides
 * only which login the finished reset returns to.
 */
export default async function Reset({
  searchParams,
}: {
  searchParams: { role?: string };
}) {
  const instructor = searchParams?.role === "instructor";
  const slug = currentSlug();
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug ?? "" });
  const studio = (Array.isArray(data) ? data[0] : data) as
    { name?: string; accent_color?: string | null; theme_preset?: string | null } | null;

  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const vars = themeVars(preset, studio?.accent_color ?? neutralAccent(preset)) as React.CSSProperties;

  // The recovery session set by /auth/callback. getClaims verifies locally
  // (middleware already refreshed); null means no valid recovery session.
  const supabase = createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const hasSession = !!claims?.claims?.sub;

  return (
    <div className="m-page min-h-screen" style={vars}>
      <main className="mx-auto max-w-lg px-4 py-12">
        <p className="m-sub text-ink-3">{studio?.name ?? "Studio"}</p>
        {hasSession ? (
          <>
            <h1 className="m-head mt-1 text-[24px] leading-8 text-ink">Set a new password</h1>
            <ResetForm role={instructor ? "instructor" : "member"} />
          </>
        ) : (
          <>
            <h1 className="m-head mt-1 text-[24px] leading-8 text-ink">This link has expired</h1>
            <p className="m-sub mt-2 text-ink-2">
              Reset links last an hour. Ask for a fresh one and try again.
            </p>
            <Link
              href={instructor ? "/forgot?role=instructor" : "/forgot"}
              className="m-micro mt-4 block text-center text-ink underline underline-offset-4"
            >
              Send a new reset link
            </Link>
          </>
        )}
      </main>
    </div>
  );
}
