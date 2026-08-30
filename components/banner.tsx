import Link from "next/link";

/**
 * The one contextual banner slot.
 *
 * Priority is money, then blocked members, then operations: a payment failure
 * and a past-due membership cost the studio money if they go unseen, setup
 * being incomplete blocks the studio from working at all, and an under-booked
 * class is a nudge. Nudges do not outrank problems, so when several qualify
 * the highest wins and the rest wait their turn — which is the whole point of
 * having one slot rather than a stack.
 */
export type BannerKind = "payment_failed" | "past_due" | "setup" | "under_booked";

const RANK: BannerKind[] = ["payment_failed", "past_due", "setup", "under_booked"];

export type BannerMsg = {
  kind: BannerKind;
  text: string;
  action?: { href: string; label: string };
};

/** Highest-priority message, or null. */
export function topBanner(msgs: (BannerMsg | null | undefined)[]): BannerMsg | null {
  const live = msgs.filter(Boolean) as BannerMsg[];
  for (const k of RANK) {
    const hit = live.find((m) => m.kind === k);
    if (hit) return hit;
  }
  return null;
}

export default function Banner({ msg }: { msg: BannerMsg | null }) {
  if (!msg) return null;
  // Money and blocked members get coral; an operational nudge does not, or the
  // colour stops meaning anything. Either way the sentence is ink: #D9401A is
  // 4.47 on white and cannot legally set body text.
  const urgent = msg.kind === "payment_failed" || msg.kind === "past_due";
  return (
    <div
      className={`mb-6 flex flex-wrap items-center gap-x-3 gap-y-1 border-l-[3px] px-3 py-2.5 ${
        urgent ? "bg-coral-tint" : "bg-lime-tint"
      }`}
      style={{ borderLeftColor: urgent ? "var(--coral)" : "var(--lime-text)" }}
      role="status"
    >
      <p className="text-[13px] leading-[18px] text-ink">{msg.text}</p>
      {msg.action && (
        <Link
          href={msg.action.href}
          className="text-[13px] font-medium leading-[18px] text-lime-text underline underline-offset-4 hover:text-lime-text2"
        >
          {msg.action.label}
        </Link>
      )}
    </div>
  );
}
