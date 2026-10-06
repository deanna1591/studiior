import Link from "next/link";

/**
 * Decision 71 — a standalone setting (Stripe, Xendit, store apps, closures,
 * check-in code, horizon, waiver, plans) rendered on its group page as a one-
 * line summary of its current state with a link to its own route. Owner-only
 * rows a manager cannot act on are greyed with "Owner only" instead of a link.
 */
export default function SettingsSummaryRow({
  title, state, href, cta = "Open", ownerLocked = false,
}: {
  title: string;
  state: string;
  href: string;
  cta?: string;
  ownerLocked?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-3 rounded border border-line bg-surface px-3.5 py-3">
      <span className="min-w-0">
        <span className="block text-[13px] font-medium text-ink">{title}</span>
        <span className="block truncate text-[12px] text-ink-3">{state}</span>
      </span>
      {ownerLocked ? (
        <span className="shrink-0 text-[12px] text-ink-3">Owner only</span>
      ) : (
        <Link href={href}
              className="shrink-0 rounded border border-line px-3 py-1.5 text-[13px] font-medium text-ink hover:bg-paper">
          {cta} →
        </Link>
      )}
    </div>
  );
}
