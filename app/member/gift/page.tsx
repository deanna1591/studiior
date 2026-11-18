import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import { formatMoney } from "@/lib/plans";
import type { Database } from "@/lib/database.types";
import GiftForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 110: the public gift-card page. A logged-out visitor buys a gift for
 * the studio — no account. Themed to the studio; buyGift opens the Xendit
 * session and the webhook issues the card on payment.
 */
export default async function GiftPage() {
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
  const currency = studio?.currency ?? "PHP";
  const presets = (studio?.gift_presets ?? [100000, 250000, 500000]) as number[];
  const minCents = studio?.gift_min_cents ?? 50000;

  if (!studio || !studio.gift_enabled) {
    return (
      <div style={vars} className="min-h-dvh bg-paper">
        <main className="mx-auto max-w-lg px-5 py-16 text-center">
          <h1 className="m-head text-[22px] leading-7 text-ink">Gift cards</h1>
          <p className="m-body mt-2 text-ink-2">
            {studio ? `${studio.name} isn't offering gift cards right now.` : "This page isn't available."}
          </p>
        </main>
      </div>
    );
  }

  return (
    <div style={vars} className="min-h-dvh bg-paper">
      <main className="mx-auto max-w-lg px-5 py-8">
        <header className="mb-5 flex items-center gap-3">
          {studio.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt="" width={44} height={44}
                 className="h-11 w-11 rounded-xl object-contain" decoding="async" />
          ) : null}
          <div>
            <p className="m-micro text-ink-3">{studio.name}</p>
            <h1 className="m-head text-[24px] leading-8 text-ink">Give a gift card</h1>
          </div>
        </header>

        <p className="m-body mb-5 text-ink-2">
          A gift card for {studio.name}, sent to whoever you choose. They redeem it in their
          account and it is theirs to spend on classes — it never expires.
        </p>

        <GiftForm
          presets={presets}
          minCents={minCents}
          currencyLabels={presets.map((c) => formatMoney(c, currency))}
          minLabel={formatMoney(minCents, currency)}
          currency={currency}
        />
      </main>
    </div>
  );
}
