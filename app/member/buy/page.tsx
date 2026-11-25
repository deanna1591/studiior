import Link from "next/link";
import type { Metadata } from "next";
import { buyStudio, planIncludes } from "@/lib/buy-plans";
import { PriceAmount, PromoTagChip } from "@/components/price-tag";
import BuyFrame from "./frame";

export const dynamic = "force-dynamic";

export async function generateMetadata(): Promise<Metadata> {
  const studio = await buyStudio();
  return { title: studio ? `Plans · ${studio.name}` : "Plans" };
}

/**
 * Decision 118: every plan the studio sells, buyable without an account.
 * Featured plans first (Decision 74), each with today's price (Decision 117).
 */
export default async function BuyAll() {
  const studio = await buyStudio();
  if (!studio) {
    return (
      <BuyFrame studio={null} title="Plans">
        <p className="m-body text-ink-2">This page isn&rsquo;t available.</p>
      </BuyFrame>
    );
  }
  return (
    <BuyFrame studio={studio} title="Plans">
      {!studio.online ? (
        <section className="m-card p-5">
          <p className="m-body text-ink">Online payment isn&rsquo;t set up yet. Pay at the studio.</p>
        </section>
      ) : studio.plans.length === 0 ? (
        <section className="m-card p-5">
          <p className="m-body text-ink">There are no plans on sale online right now. Ask the studio.</p>
        </section>
      ) : (
        <>
          <p className="m-body mb-4 text-ink-2">
            Buy now, no account needed. Your plan starts on the day you set up your account, so you lose no days.
          </p>
          <ul className="space-y-3">
            {studio.plans.map((p) => (
              <li key={p.id}>
                <Link href={`/buy/${p.id}`}
                      className="m-card m-press block p-5"
                      style={p.featured ? { boxShadow: "inset 0 0 0 2px var(--accent-solid)" } : undefined}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="m-head text-[18px] leading-6 text-ink">{p.name}</p>
                      {p.badge && (
                        <span className="m-micro mt-1 inline-block rounded-full px-2 py-0.5"
                              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>{p.badge}</span>
                      )}
                      <p className="m-sub mt-1 text-ink-2">{planIncludes(p).join(" · ")}</p>
                    </div>
                    <div className="shrink-0 text-right">
                      <PriceAmount priceCents={p.price.price_cents} listCents={p.price.list_cents}
                                   currency={p.price.currency} promo={p.price} />
                    </div>
                  </div>
                  <PromoTagChip promo={p.price} className="mt-2" />
                  {p.full && <p className="m-sub mt-2 text-ink-2">This plan is full. Ask the studio.</p>}
                </Link>
              </li>
            ))}
          </ul>
          <p className="m-sub mt-6 text-center text-ink-2">
            Already have an account? <Link href="/login?next=%2Faccount%2Fplan" className="text-ink underline underline-offset-4">Sign in</Link>
          </p>
        </>
      )}
    </BuyFrame>
  );
}
