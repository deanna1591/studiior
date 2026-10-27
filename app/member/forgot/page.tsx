import Link from "next/link";
import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { Database } from "@/lib/database.types";
import ForgotForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 84 — forgot password, one page for member and instructor.
 *
 * Both sign in on the same host; only the post-reset login differs, so the
 * instructor link passes ?role=instructor and that role travels through the
 * reset link into the /reset page. Branded as the studio through the same
 * pre-login lookup the login screens use.
 */
export default async function Forgot({
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

  return (
    <div className="m-page min-h-screen" style={vars}>
      <main className="mx-auto max-w-lg px-4 py-12">
        <p className="m-sub text-ink-3">{studio?.name ?? "Studio"}</p>
        <h1 className="m-head mt-1 text-[24px] leading-8 text-ink">Reset your password</h1>
        <p className="m-sub mt-2 text-ink-2">
          Enter your email and we&rsquo;ll send a link to set a new password.
        </p>
        <ForgotForm instructor={instructor} />
        <Link
          href={instructor ? "/instructor/login" : "/login"}
          className="m-micro mt-4 block text-center text-ink-3 underline underline-offset-4"
        >
          Back to sign in
        </Link>
      </main>
    </div>
  );
}
