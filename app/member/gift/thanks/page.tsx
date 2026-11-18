import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { Database } from "@/lib/database.types";

export const dynamic = "force-dynamic";

/**
 * Decision 110: the gift buyer lands here after paying. The card is issued by
 * the webhook (not synchronously), so this confirms it is on its way.
 */
export default async function GiftThanks() {
  const slug = currentSlug();
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data: s } = await anon.rpc("studio_by_slug", { p_slug: slug ?? "" });
  const studio = Array.isArray(s) ? s[0] : s;
  const preset = (studio?.theme_preset ?? "warm") as PresetKey;
  const accent = studio?.accent_color ?? neutralAccent(preset);
  const vars = themeVars(preset, accent) as React.CSSProperties;

  return (
    <div style={vars} className="min-h-dvh bg-paper">
      <main className="mx-auto max-w-lg px-5 py-16 text-center">
        <h1 className="m-head text-[24px] leading-8 text-ink">Thank you</h1>
        <p className="m-body mt-3 text-ink-2">
          Your gift card for {studio?.name ?? "the studio"} is on its way. We've emailed you a
          receipt with the code, and we'll send the card to your recipient
          {" "}— at once, or on the date you chose.
        </p>
      </main>
    </div>
  );
}
