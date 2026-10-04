/**
 * A small status chip for a member's plan_state (member list) and a purchase's
 * sale_status (Sales).
 *
 * No new colours: the floor is 4.5:1, so a studio-arbitrary fill behind a word
 * is not on the table. Muted is ink-2 on paper with a hairline — the shape that
 * reads as a label rather than a verdict; the one tone it earns is amber-tint
 * for "expiring", the single state a studio would act on, where ink measures
 * 11.09. Everything else (expired, refunded, unpaid, free-only, none) is muted,
 * per Decision 49's own instruction.
 */
const CHIP: Record<string, { label: string; warn?: boolean }> = {
  // Decision 61: a granted free membership — not a sale.
  complimentary: { label: "Complimentary" },
  // plan_state (member_plan_overview)
  on_plan: { label: "On a plan" },
  expiring: { label: "Expiring", warn: true },
  expired: { label: "Expired" },
  free_only: { label: "Free class only" },
  none: { label: "No plan" },
  // sale_status (sales_history)
  active: { label: "Active" },
  refunded: { label: "Refunded" },
  unpaid: { label: "Unpaid" },
  frozen: { label: "Paused" },
  // campaign status (Decision 50)
  draft: { label: "Draft" },
  scheduled: { label: "Scheduled", warn: true },
  sending: { label: "Sending", warn: true },
  sent: { label: "Sent" },
  cancelled: { label: "Cancelled" },
};

export function StateChip({ state }: { state: string }) {
  const c = CHIP[state] ?? { label: state.replace(/_/g, " ") };
  return (
    <span
      className={`inline-flex items-center rounded-sm border px-1.5 py-px text-[11px] leading-4 ${
        c.warn ? "border-line-2 bg-amber-tint text-ink" : "border-line-2 bg-paper text-ink-2"
      }`}
    >
      {c.label}
    </span>
  );
}
