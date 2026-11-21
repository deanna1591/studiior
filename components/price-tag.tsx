import { formatMoney } from "@/lib/plans";
import { promoTag, type PlanPrice } from "@/lib/promo";

/**
 * Decision 117 — the one price display. While a promotion runs the sale price
 * shows with the list price struck through; the tag says the promotion, the
 * percent and its last day. Outside the dates: the list price, no tag. Shared by
 * Account → Plans, the checkout picker, /buy, the private pay step and the
 * staff sell sheets, so the wording cannot drift.
 *
 * The struck price takes --ink-2 (safe on a card and on the page wash); the tag
 * is --ink on --accent-chip, the measured pair.
 */
export function PriceAmount({ priceCents, listCents, currency, promo, className = "" }: {
  priceCents: number; listCents?: number | null; currency: string;
  promo?: PlanPrice | null; className?: string;
}) {
  const struck = promo?.promotion_id && listCents != null && listCents > priceCents;
  return (
    <span className={`num ${className}`}>
      {struck && (
        <s className="mr-1.5 font-normal text-ink-2" aria-label={`was ${formatMoney(listCents!, currency)}`}>
          {formatMoney(listCents!, currency)}
        </s>
      )}
      {formatMoney(priceCents, currency)}
    </span>
  );
}

export function PromoTagChip({ promo, className = "" }: { promo?: PlanPrice | null; className?: string }) {
  const tag = promoTag(promo);
  if (!tag) return null;
  return (
    <span className={`inline-block rounded-full px-2 py-0.5 text-[11.5px] font-medium leading-4 text-ink ${className}`}
          style={{ background: "var(--accent-chip)" }}>
      {tag}
    </span>
  );
}
