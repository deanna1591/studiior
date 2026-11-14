import { formatMoney } from "@/lib/plans";
import { creditOnCheckout, creditLines } from "@/lib/reservation-credit";

/**
 * Decision 103a: the reservation-credit lines shown above a checkout total —
 * "₱{applied} reservation credit applied." and, when credit remains,
 * "₱{remaining} stays on your account." Renders nothing when there is no credit
 * or none applies (a purchase at or below the processor floor). Presentational,
 * usable in server and client components.
 */
export default function CreditApplied({
  creditCents, priceCents, currency, className,
}: {
  creditCents: number;
  priceCents: number;
  currency: string;
  className?: string;
}) {
  const { applied, remaining } = creditOnCheckout(creditCents, priceCents);
  const lines = creditLines(applied, remaining, (c: number) => formatMoney(c, currency));
  if (lines.length === 0) return null;
  return (
    <div className={className ?? "mt-2 text-[13px] text-lime-text"}>
      {lines.map((l, i) => (
        <p key={i}>{l}</p>
      ))}
    </div>
  );
}
