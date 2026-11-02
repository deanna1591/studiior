// Types for the pure checkout helpers in lib/checkout.mjs.

export type CheckoutPlan = {
  id: string;
  type: "drop_in" | "trial" | "class_pack" | "recurring" | "group" | string;
  price_cents: number;
  currency: string;
  credits: number | null;
  credits_per_period: number | null;
  validity_days: number | null;
  billing_interval: string | null;
  [k: string]: unknown;
};

export function checkoutPlanOrder<T extends CheckoutPlan>(
  plans: T[] | null | undefined,
  opts?: { trialUsed?: boolean; introPlanId?: string | null; hideExclusiveIntro?: boolean },
): T[];

export function planHelpLine(plan: CheckoutPlan | null | undefined): string;

export function checkoutTotalCents(plan: CheckoutPlan | null | undefined): number;
