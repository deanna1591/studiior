import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/lib/database.types";
import { currentSlug } from "@/lib/tenant";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import LoginForm from "./form";

export const dynamic = "force-dynamic";

/**
 * The instructor sign-in.
 *
 * Its own screen rather than the member one, because the two land in different
 * places and a single form that guessed would sometimes guess wrong. Branded
 * as the studio through the same pre-login lookup the member login uses.
 */
export default async function InstructorLogin() {
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
  const vars = themeVars(
    preset, studio?.accent_color ?? neutralAccent(preset),
  ) as React.CSSProperties;

  return (
    <div className="m-page min-h-screen" style={vars}>
      <main className="mx-auto max-w-lg px-4 py-12">
        <p className="m-sub text-ink-3">{studio?.name ?? "Studio"}</p>
        <h1 className="m-head mt-1 text-[24px] leading-8 text-ink">Instructors</h1>
        <p className="m-sub mt-2 text-ink-2">
          Your week, your rosters, cover, availability and what you are owed.
        </p>
        <LoginForm />
      </main>
    </div>
  );
}
