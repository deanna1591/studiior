import type { Database } from "@/lib/database.types";

export type PlanType = Database["public"]["Enums"]["plan_type"];
export type BillingInterval = Database["public"]["Enums"]["billing_interval"];

/**
 * Which fields mean anything for a given plan type.
 *
 * billing_interval on a ten-class pack is not a field the owner should have to
 * ignore — it is a field that should not be there. This drives both the form
 * and the server-side normalisation, so what the screen hides the action also
 * refuses to store: a hidden input is not a constraint.
 */
export type FieldSet = {
  billing: boolean;           // billing_interval, billing_interval_count
  credits: boolean;           // credits — pack only: a bundle bought once (Decision 12)
  creditsPerPeriod: boolean;  // credits_per_period — recurring only; null = unlimited (Decision 12)
  validity: boolean;          // validity_days
  commitment: boolean;        // commitment_months, cancellation_notice_days
  freeze: boolean;            // freeze_allowed, max_freeze_days
};

export const FIELDS: Record<PlanType, FieldSet> = {
  recurring:  { billing: true,  credits: false, creditsPerPeriod: true,  validity: false, commitment: true,  freeze: true  },
  class_pack: { billing: false, credits: true,  creditsPerPeriod: false, validity: true,  commitment: false, freeze: false },
  drop_in:    { billing: false, credits: true,  creditsPerPeriod: false, validity: true,  commitment: false, freeze: false },
  trial:      { billing: false, credits: true,  creditsPerPeriod: false, validity: true,  commitment: false, freeze: false },
};

export const PLAN_TYPE_LABEL: Record<PlanType, string> = {
  recurring: "Recurring membership",
  class_pack: "Class pack",
  drop_in: "Drop-in",
  trial: "Intro offer / trial",
};

export const PLAN_TYPE_HINT: Record<PlanType, string> = {
  recurring:
    "Bills on a schedule until cancelled. Leave the per-period allowance empty for unlimited — that is what unlimited means here (Decision 12).",
  class_pack:
    "Bought once, a fixed number of classes, expiring after a set number of days.",
  drop_in: "One class, bought and used.",
  trial:
    "A plan type, not a flag — it converts or expires (§7.1). Usually a few classes over a short window.",
};

export const VISIBILITY_LABEL: Record<string, string> = {
  public: "Public — members can see and buy it",
  hidden: "Hidden — sellable by staff, not listed to members",
  staff_only: "Staff only — never shown to members",
};

/** Money in, cents out. Never a float (CLAUDE.md). */
export function toCents(input: string): number | null {
  const trimmed = input.trim();
  if (trimmed === "") return null;
  if (!/^\d+(\.\d{0,2})?$/.test(trimmed)) return null;
  const [whole, frac = ""] = trimmed.split(".");
  return Number(whole) * 100 + Number(frac.padEnd(2, "0"));
}

export function fromCents(cents: number): string {
  return (cents / 100).toFixed(2);
}

export function formatMoney(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(cents / 100);
  } catch {
    return `${fromCents(cents)} ${currency}`;
  }
}
