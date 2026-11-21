export type PlanPrice = {
  plan_id: string;
  list_cents: number;
  price_cents: number;
  discount_cents: number;
  currency: string;
  promotion_id: string | null;
  promotion_name: string | null;
  pct: number | null;
  ends_on: string | null;
  ends_label: string | null;
};
export function salePriceCents(listCents: number, pct: number): number;
export function promoTag(p: PlanPrice | null | undefined): string | null;
export function saleAppliedLine(p: PlanPrice | null | undefined): string | null;
export function pctOffLabel(pct: number | null | undefined): string | null;
export function withPrice<T extends { id: string; price_cents: number }>(
  plan: T, prices: Map<string, PlanPrice> | null | undefined,
): T & { list_cents: number; promo: PlanPrice | null };
