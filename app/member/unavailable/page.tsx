import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { themeVars, accentRamp, neutralAccent, accentGradient, type PresetKey } from "@/lib/theme";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";

/**
 * What a member sees when their studio is locked.
 *
 * They did nothing wrong, so this says as little as possible: not that the
 * studio has not paid, not what it costs, not whose fault it is. Their studio's
 * business with us is not their business, and a member who reads "your studio's
 * subscription lapsed" now knows something about their instructor's finances
 * that they were never entitled to.
 *
 * Branded as the studio, like every other member screen, and resolved through
 * studio_by_slug() because the member may not even be signed in.
 */
export default async function Unavailable() {
  const slug = currentSlug();
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = slug ? await anon.rpc("studio_by_slug", { p_slug: slug }) : { data: null };
  const studio = Array.isArray(data) ? data[0] : data;

  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const accent = studio?.accent_color ?? neutralAccent(preset);
  const ramp = accentRamp(accent, preset);
  const [from, to] = accentGradient(ramp);

  return (
    <div style={themeVars(preset, accent) as React.CSSProperties}
         className="relative flex min-h-dvh flex-col items-center justify-center px-8 text-center">
      <div aria-hidden className="absolute inset-0"
           style={{ background: `linear-gradient(160deg, ${from} 0%, ${to} 100%)` }} />
      <div className="relative">
        <h1 className="m-title" style={{ color: ramp.onSolid }}>
          {studio?.name ?? "This studio"} isn&rsquo;t taking bookings right now
        </h1>
        <p className="m-body mt-3" style={{ color: ramp.onSolid }}>
          Nothing has happened to your account or your class history. Get in
          touch with the studio and they&rsquo;ll let you know when it&rsquo;s back.
        </p>
      </div>
    </div>
  );
}
