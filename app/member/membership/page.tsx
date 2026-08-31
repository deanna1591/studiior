import Link from "next/link";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts } from "@/lib/time";
import { signOut } from "../actions";

export const dynamic = "force-dynamic";

export default async function Membership() {
  const { ctx, supabase, studioName, logoUrl, preset, accent } = await memberScreen();
  const { live, all } = await membershipState(supabase, ctx.memberId);

  // Credits with the date they run out. The ledger is the truth; the number on
  // the membership is a cache of it.
  const { data: ledger } = await supabase
    .from("credit_ledger")
    .select("id, delta, reason, balance_after, expires_at, created_at, membership_id")
    .eq("member_id", ctx.memberId)
    .order("created_at", { ascending: false })
    .limit(20);

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };

  // Scoped to the plan on screen. A member with two packs open has credits
  // expiring on two different dates, and reading the earliest from the whole
  // ledger produced "use them by 9 January" directly above "runs until 30
  // September" — two true dates describing two different things.
  const nextExpiry = (ledger ?? [])
    .filter((c) => c.delta > 0 && c.expires_at
                && (!live || c.membership_id === live.id)
                && new Date(c.expires_at) > new Date())
    .sort((a, b) => new Date(a.expires_at!).getTime() - new Date(b.expires_at!).getTime())[0];

  const pastDue = live?.status === "past_due";

  return (
    <MemberShell studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Your plan">
      {pastDue && (
        <div className="mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="m-sub text-ink">
            Your last payment didn&rsquo;t go through. Pop into the studio or reply
            to our email and we&rsquo;ll sort it.
          </p>
        </div>
      )}

      {!live ? (
        <div className="rounded-xl border border-dashed border-line-2 p-5 text-center">
          <p className="m-body text-ink">No plan yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            The studio can set you up with one at the desk, and then classes are
            a tap away.{" "}
            <Link href="/book" className="text-lime-text underline underline-offset-4">
              See what&rsquo;s on
            </Link>
            .
          </p>
        </div>
      ) : (
        <section className="rounded-xl border border-line bg-surface p-4">
          <h2 className="m-display text-ink">{live.membership_plans?.name}</h2>
          <p className="m-sub mt-1 text-ink-2">
            <span className="num">{formatMoney(live.price_cents, live.currency)}</span>
            {live.status !== "active" && <> · {live.status.replace("_", " ")}</>}
          </p>

          <div className="mt-4 border-t border-line pt-3">
            <p className="m-micro text-ink-3">Classes left</p>
            <p className="text-ink">
              {live.credits_remaining === null
                ? <span className="m-body">Unlimited</span>
                : <span className="num text-[30px] leading-9">{live.credits_remaining}</span>}
            </p>
            {nextExpiry?.expires_at && (
              <p className="m-micro mt-1 text-ink-2">
                Use them by {d(nextExpiry.expires_at)}.
              </p>
            )}
          </div>

          <div className="mt-4 border-t border-line pt-3">
            {live.renews_on ? (
              <p className="m-sub text-ink-2">
                Renews {d(live.renews_on)}
                {!live.auto_renew && " — and then stops, as you asked"}.
              </p>
            ) : live.expires_on ? (
              <p className="m-sub text-ink-2">Runs until {d(live.expires_on)}.</p>
            ) : (
              <p className="m-sub text-ink-2">No end date.</p>
            )}
          </div>
        </section>
      )}

      {(ledger ?? []).length > 0 && (
        <section className="mt-5">
          <h2 className="m-sub mb-2 font-medium text-ink">Recent activity</h2>
          <ul className="divide-y divide-line rounded-xl border border-line bg-surface">
            {(ledger ?? []).slice(0, 8).map((c) => (
              <li key={c.id} className="flex items-baseline justify-between gap-3 px-3 py-2">
                <span className="m-sub min-w-0 truncate text-ink-2">
                  {c.reason === "booking" ? "Booked a class"
                    : c.reason === "cancellation_refund" ? "Cancelled — credit back"
                    : c.reason === "purchase" ? "Bought a pack"
                    : c.reason === "expiry" ? "Credits expired"
                    : c.reason.replace(/_/g, " ")}
                  <span className="m-micro ml-1.5 text-ink-3">{d(c.created_at)}</span>
                </span>
                <span className="num shrink-0 text-[14px] text-ink">
                  {c.delta > 0 ? `+${c.delta}` : c.delta}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {all.length > 1 && (
        <p className="m-micro mt-3 text-ink-3">
          You have had {all.length} plans with {studioName}. Older ones keep the
          price you paid at the time.
        </p>
      )}

      <Link href="/settings"
            className="m-tap mt-8 flex w-full items-center justify-center rounded-lg border border-line-2 bg-surface text-[14px] text-ink-2">
        Email settings
      </Link>

      <form action={signOut} className="mt-3">
        <button className="m-tap w-full rounded-lg border border-line-2 bg-surface text-[14px] text-ink-2">
          Sign out
        </button>
      </form>
    </MemberShell>
  );
}
