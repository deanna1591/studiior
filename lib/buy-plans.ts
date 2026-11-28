import { createServerClient } from "@supabase/ssr";
import { currentSlug } from "@/lib/tenant";
import type { Database } from "@/lib/database.types";
import type { PlanPrice } from "@/lib/promo";

/** Decision 118: one plan anybody may buy, as studio_by_slug(p_with_plans) carries it. */
export type BuyablePlan = {
  id: string; name: string; description: string | null; type: string;
  credits: number | null; validity_days: number | null;
  credits_per_period: number | null; billing_interval: string | null;
  featured: boolean; badge: string | null; group_size: number | null;
  private_pack: boolean; full: boolean;
  /** Decision 24 (a): the plan's cap on the number ever sold is reached. */
  sold_out?: boolean;
  price: PlanPrice;
};

export type BuyStudio = {
  id: string; name: string; slug: string; logo_url: string | null;
  theme_preset: string | null; accent_color: string | null; currency: string;
  online: boolean; plans: BuyablePlan[]; contact_email: string | null;
  /** Decision 103 (p): the studio takes payment online only. */
  staff_only: boolean;
};

/**
 * The studio for the current member host with the plans anybody may buy, read
 * through studio_by_slug (already public) on a cookie-less anon client. Null for
 * an unknown host. Prices are plan_price_now_run's, so a running promotion shows.
 */
export async function buyStudio(): Promise<BuyStudio | null> {
  const slug = currentSlug();
  if (!slug) return null;
  const anon = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
  const { data } = await anon.rpc("studio_by_slug", { p_slug: slug, p_with_plans: true });
  const s = Array.isArray(data) ? data[0] : data;
  if (!s) return null;
  const buy = (s.buy ?? {}) as { online?: boolean; plans?: BuyablePlan[]; contact_email?: string | null; staff_only?: boolean };
  return {
    id: s.id, name: s.name, slug: s.slug, logo_url: s.logo_url,
    theme_preset: s.theme_preset, accent_color: s.accent_color, currency: s.currency,
    online: buy.online === true, plans: buy.plans ?? [], contact_email: buy.contact_email ?? null,
    staff_only: buy.staff_only === true,
  };
}

const PERIOD: Record<string, string> = { week: "week", month: "month", year: "year" };

/** What a plan gives, in a few words, for the public buy pages. */
export function planIncludes(p: BuyablePlan): string[] {
  if (p.type === "recurring") {
    const per = p.billing_interval ? PERIOD[p.billing_interval] ?? "period" : "period";
    return [
      p.credits_per_period == null ? "Unlimited classes" : `${p.credits_per_period} class${p.credits_per_period === 1 ? "" : "es"} a ${per}`,
      `one ${per}, starts when you set up your account`,
    ];
  }
  if (p.type === "group") {
    return [`for ${p.group_size ?? 2} people`, "book one class together"];
  }
  if (p.type === "drop_in") {
    return ["Single class", p.validity_days ? `use within ${p.validity_days} days` : ""].filter(Boolean);
  }
  return [
    p.credits != null
      ? (p.private_pack ? `${p.credits} private session${p.credits === 1 ? "" : "s"}` : `${p.credits} class${p.credits === 1 ? "" : "es"}`)
      : "",
    p.validity_days ? `use within ${p.validity_days} days of setting up` : "",
  ].filter(Boolean);
}
