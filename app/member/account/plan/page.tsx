import Link from "next/link";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import { dayMonthParts, addDays, dayStart } from "@/lib/time";

export const dynamic = "force-dynamic";

export default async function Plan() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();
  const { live, all } = await membershipState(supabase, ctx.memberId);

  const from = dayStart(new Date(), ctx.timeZone, 0);
  const to = addDays(from, 30);
  // guest_passes_enabled arrives with the member (bootstrap). This batch is the
  // three reads that actually need a query: the ledger, the active-guest count
  // (only when guest passes are on), and the peak slots.
  const guestEnabled = settings.guestPassesEnabled;
  const [{ data: ledger }, { count: activeGuests }, { data: peak }, { data: freeElig }, { data: catalogue }] =
    await Promise.all([
      supabase.from("credit_ledger")
        .select("id, delta, expires_at, created_at, membership_id")
        .eq("member_id", ctx.memberId).order("created_at", { ascending: false }).limit(30),
      guestEnabled
        ? supabase.from("guest_passes").select("id", { count: "exact", head: true })
            .eq("host_member_id", ctx.memberId).in("status", ["invited", "confirmed"])
        : Promise.resolve({ count: 0 }),
      supabase.rpc("member_peak_slots", { p_studio_id: ctx.studioId, p_from: from.toISOString(), p_to: to.toISOString() }),
      // Decision 30: a first-timer owed a free class sees why to book before buying.
      supabase.rpc("free_first_eligibility", { p_studio_id: ctx.studioId, p_member_id: ctx.memberId }),
      // The studio's public plans, so "the plans are here" leads somewhere. RLS
      // (plans_member_read) already limits this to this studio's visibility=
      // 'public' plans — Permissions §9. Purchase is at the desk (Decision 16).
      supabase.from("membership_plans")
        .select("id, name, description, type, price_cents, currency, credits, credits_per_period, validity_days, billing_interval, billing_interval_count")
        .eq("visibility", "public").eq("status", "active").order("sort_order"),
    ]);
  const freeFirstEligible = (freeElig as { ok?: boolean } | null)?.ok === true;
  const peakLine = (peak ?? []).find((r) => r.is_peak && r.remaining !== null);

  const d = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return <><span className="num">{day}</span> {month}</>;
  };
  const dateUTC = (iso: string) => new Intl.DateTimeFormat("en-GB",
    { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));

  const nextExpiry = (ledger ?? [])
    .filter((c) => c.delta > 0 && c.expires_at && (!live || c.membership_id === live.id)
                && new Date(c.expires_at) > new Date())
    .sort((a, b) => new Date(a.expires_at!).getTime() - new Date(b.expires_at!).getTime())[0];

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">Your plan</h1>

      {freeFirstEligible && (
        <div className="m-card mb-3 p-4">
          <p className="text-[15px] font-semibold leading-5 text-ink">Your first class is on us</p>
          <p className="m-sub mt-1 text-ink-2">
            Try a class free before you pick a plan — no card needed.{" "}
            <Link href="/book" className="text-lime-text underline underline-offset-4">Book your free class</Link>.
          </p>
        </div>
      )}
      {!live ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">No plan yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            The studio can set you up with one at the desk.{" "}
            <Link href="/book" className="text-lime-text underline underline-offset-4">See what&rsquo;s on</Link>.
          </p>
        </div>
      ) : (
        <section className="m-card p-4">
          <h2 className="m-head text-[24px] leading-8 text-ink">{live.membership_plans?.name}</h2>
          <p className="m-sub mt-1 text-ink-2">
            <span className="num">{formatMoney(live.price_cents, live.currency)}</span>
            {live.status !== "active" && <> · {live.status.replace("_", " ")}</>}
          </p>

          <div className="mt-4 border-t border-line pt-3">
            <p className="m-micro text-ink-3">Classes left</p>
            {live.credits_remaining === null
              ? <p className="m-body text-ink">Unlimited</p>
              : <p className="num text-[30px] leading-9 text-ink">{live.credits_remaining}</p>}
            {nextExpiry?.expires_at && <p className="m-micro mt-1 text-ink-2">Use them by {d(nextExpiry.expires_at)}.</p>}
          </div>

          <div className="mt-4 border-t border-line pt-3">
            {live.status === "past_due" ? (
              <p className="m-sub text-ink">Your membership was due for renewal{live.renews_on && <> on {d(live.renews_on)}</>}. You can still book for now — have a word with the studio.</p>
            ) : live.renews_on ? (
              <p className="m-sub text-ink-2">Renews {d(live.renews_on)}{!live.auto_renew && " — and then stops, as you asked"}.</p>
            ) : live.expires_on ? (
              <p className="m-sub text-ink-2">Runs until {d(live.expires_on)}.</p>
            ) : <p className="m-sub text-ink-2">No end date.</p>}
          </div>

          {/* Peak — only when the studio runs peak allowances and this member has one. */}
          {peakLine && (
            <div className="mt-4 border-t border-line pt-3">
              <p className="m-micro text-ink-3">Peak classes this period</p>
              <p className="text-ink"><span className="num text-[20px] font-semibold">{peakLine.remaining}</span>
                <span className="m-sub text-ink-3"> of {peakLine.allowance} left</span></p>
              {peakLine.period_end && <p className="m-micro mt-1 text-ink-2">Resets {dateUTC(peakLine.period_end)}. Off-peak classes are unlimited.</p>}
            </div>
          )}

          {/* Guest — only when the studio lets members bring one. */}
          {guestEnabled && (
            <div className="mt-4 border-t border-line pt-3">
              <p className="m-micro text-ink-3">Guest pass</p>
              <p className="m-sub text-ink-2">
                {(activeGuests ?? 0) > 0
                  ? "Your guest is booked. You can bring another once they have come."
                  : "You can bring a guest — their first class is free. Add them when you book a class."}
              </p>
            </div>
          )}
        </section>
      )}

      {all.length > 1 && (
        <p className="m-micro mt-3 text-ink-3">
          You have had {all.length} plans with {studioName}. Older ones keep the price you paid at the time.
        </p>
      )}

      {/* The catalogue. Decision 16: no online checkout — the studio sells at the
          desk — but "the plans are here" has to actually show the plans and their
          prices, or the free-class conversion has nowhere to land. */}
      {(catalogue ?? []).length > 0 && (
        <section className="mt-8">
          <h2 className="section-label text-ink-2">{live ? "Other plans" : "Plans"}</h2>
          <ul className="mt-3 space-y-3">
            {(catalogue ?? []).map((p) => {
              const includes = p.type === "class_pack"
                ? [p.credits != null ? `${p.credits} classes` : null,
                   p.validity_days ? `use within ${p.validity_days} days` : null]
                : p.type === "drop_in"
                ? ["Single class"]
                : [p.credits_per_period == null ? "Unlimited classes" : `${p.credits_per_period} classes each period`,
                   p.billing_interval
                     ? `billed ${(p.billing_interval_count ?? 1) > 1
                          ? `every ${p.billing_interval_count} ${p.billing_interval}s`
                          : `per ${p.billing_interval}`}`
                     : null];
              return (
                <li key={p.id} className="m-card p-4">
                  <div className="flex items-baseline justify-between gap-3">
                    <h3 className="text-[16px] font-semibold leading-5 text-ink">{p.name}</h3>
                    <span className="num shrink-0 text-[16px] font-semibold text-ink">
                      {formatMoney(p.price_cents, p.currency)}
                    </span>
                  </div>
                  {p.description && <p className="m-sub mt-1 text-ink-2">{p.description}</p>}
                  <p className="m-sub mt-1 text-ink-3">{includes.filter(Boolean).join(" · ")}</p>
                </li>
              );
            })}
          </ul>
          <div className="m-card mt-3 p-4">
            <p className="m-micro text-ink-3">How to buy</p>
            <p className="m-sub mt-1 whitespace-pre-line text-ink-2">
              {settings.howToBuy?.trim() || "Ask at the desk and we’ll set you up."}
            </p>
            {settings.studioContactEmail && (
              <p className="m-sub mt-1 text-ink-2">
                Or email{" "}
                <a href={`mailto:${settings.studioContactEmail}`}
                   className="text-lime-text underline underline-offset-4">
                  {settings.studioContactEmail}
                </a>.
              </p>
            )}
          </div>
        </section>
      )}
    </MemberShell>
  );
}
