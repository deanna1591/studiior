export const CREDIT_FLOOR_CENTS: number;
export function creditOnCheckout(
  creditCents: number,
  priceCents: number
): { applied: number; remaining: number };
export function netTotalCents(creditCents: number, priceCents: number): number;
export function creditLines(
  applied: number,
  remaining: number,
  fmt: (cents: number) => string
): string[];
