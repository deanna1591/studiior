import { AppShell, NavLink, Notice } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import SubscribeButton from "./form";

export const dynamic = "force-dynamic";

const fmtDate = (iso: string | null, tz: string) =>
  iso ? new Intl.DateTimeFormat("en-GB", {
    timeZone: tz, day: "numeric", month: "long", year: "numeric",
  }).format(new Date(iso)) : "";

/**
 * What the studio pays Studiior, and how to fix it when it lapses.
 *
 * Reachable while locked — it is the ONE staff screen that is, because it is
 * the way out. staffScreen() redirects everything else here.
 */
export default async function Billing({
  searchParams,
}: {
  searchParams: { paid?: string; cancelled?: string };
}) {
  const screen = await staffScreen("/billing");
  if (screen.gate) return screen.gate;
  const { ctx, shell, billing } = screen;

  const status = billing?.status ?? "trialing";
  const locked = billing?.locked ?? false;
  const days = billing?.days_left ?? 0;
  const tz = ctx.timeZone ?? "UTC";

  const headline =
    locked   ? `${ctx.studioName} is locked`
    : status === "past_due" ? `Payment needed — ${days} ${days === 1 ? "day" : "days"} left`
    : status === "active"   ? "Your subscription is active"
    : status === "cancelled" ? "Your subscription is cancelled"
    : `You're on trial — ${days} ${days === 1 ? "day" : "days"} left`;

  return (
    <AppShell {...shell} title="Billing"
              actions={!locked ? <NavLink href="/">Back to schedule</NavLink> : undefined}>
      <div className="max-w-xl space-y-4">
        {searchParams.paid && <Notice kind="ok">Thank you — your subscription is active.</Notice>}
        {searchParams.cancelled && <Notice kind="error">Checkout was cancelled. Nothing has changed.</Notice>}

        {locked && (
          <Notice kind="error">
            Staff and members are both locked out until this is sorted. Nothing
            has been deleted — every class, member and booking is exactly where
            you left it, and paying puts it all back.
          </Notice>
        )}

        <h2 className="text-[17px] font-semibold leading-6 text-ink">{headline}</h2>

        <p className="text-[14px] leading-[22px] text-ink-2">
          Studiior is <span className="num">$79</span> a month, billed in US
          dollars whatever currency you charge your own members in.
        </p>

        {status === "trialing" && (
          <p className="text-[13px] leading-5 text-ink-2">
            Your trial runs to {fmtDate(billing?.trial_ends_at ?? null, tz)}. No
            card is needed until then.
          </p>
        )}
        {(status === "past_due" || locked) && billing?.grace_ends_at && (
          <p className="text-[13px] leading-5 text-ink-2">
            {locked
              ? `Locked since ${fmtDate(billing.grace_ends_at, tz)}.`
              : `Everything keeps working until ${fmtDate(billing.grace_ends_at, tz)}. After that, staff and members are both locked out.`}
          </p>
        )}

        {ctx.role === "owner" ? (
          <SubscribeButton hasCard={billing?.has_card ?? false} />
        ) : (
          <p className="text-[13px] leading-5 text-ink-2">
            Only the studio owner can set this up.
          </p>
        )}

        {/* Said plainly rather than left to be discovered. Decision 16 makes
            how a studio takes money from ITS members entirely their own
            business; it does not make how they pay US optional. */}
        <p className="border-t border-line pt-4 text-[13px] leading-[20px] text-ink-2">
          <strong className="font-medium text-ink">Card only.</strong> You can
          take cash, bank transfers or GCash from your own members for as long
          as you like — that is your business and we do not touch it. Studiior
          itself is paid by card, because we are not set up to chase transfers.
        </p>

        <p className="text-[12px] leading-[18px] text-ink-3">
          Test mode. Nothing here charges a real card yet.
        </p>
      </div>
    </AppShell>
  );
}
