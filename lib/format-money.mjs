// Money formatting, pure so a node test can prove it. Re-exported from
// lib/plans.ts, so every existing `from "@/lib/plans"` import is unchanged.

export function fromCents(cents) {
  return (cents / 100).toFixed(2);
}

export function formatMoney(cents, currency) {
  // Decision 103(c): drop the trailing .00 for a whole amount (the processor and
  // the SQL fmt_money the emails use both do), keep two decimals for a fraction.
  const whole = cents % 100 === 0;
  try {
    return new Intl.NumberFormat("en-GB", {
      style: "currency", currency,
      minimumFractionDigits: whole ? 0 : 2,
      maximumFractionDigits: whole ? 0 : 2,
    }).format(cents / 100);
  } catch {
    return `${fromCents(cents)} ${currency}`;
  }
}
