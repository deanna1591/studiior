import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";

export const dynamic = "force-dynamic";

/**
 * The screen adapts to whether the studio has a CONNECTED PROVIDER — detected,
 * never toggled. With one, the card wallet; without one, absent (not empty), and
 * what the studio accepts plus where to pay. Decision 16: the provider is an
 * adapter over the manual foundation, and this concept is "connected provider",
 * not "Stripe" — a future PayMongo/Xendit adapter appears here with no change.
 */
export default async function HowYouPay() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();

  // The provider flag arrives with the member (bootstrap); only the contact
  // details need a query here, and only for the no-provider path.
  const { data: studio } = await supabase.from("studios")
    .select("contact_email, contact_phone").eq("id", ctx.studioId).maybeSingle();
  const hasProvider = settings.hasPaymentProvider;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">How you pay</h1>

      {hasProvider ? (
        <>
          <section className="m-card p-4">
            <p className="m-eyebrow mb-1 font-semibold text-ink">Your cards</p>
            <p className="m-sub text-ink-2">
              Add a card when you book a class or buy a plan — it is saved for next
              time, and you can remove it from the checkout screen.
            </p>
          </section>
          <p className="m-sub mt-4 text-ink-2">
            You can also pay at the studio — {studioName} still takes payment at the
            desk.
          </p>
        </>
      ) : (
        <>
          <section className="m-card p-4">
            <p className="m-eyebrow mb-1 font-semibold text-ink">Paying {studioName}</p>
            <p className="m-sub text-ink-2">
              {studioName} takes payment at the desk — cash, bank transfer, or a card
              in person. Book your class or reserve your plan in the app, then settle
              up when you come in.
            </p>
          </section>
          {(studio?.contact_email || studio?.contact_phone) && (
            <section className="m-card mt-4 p-4">
              <p className="m-eyebrow mb-1 font-semibold text-ink">Questions about a payment?</p>
              {studio?.contact_email && <p className="m-sub text-ink-2">{studio.contact_email}</p>}
              {studio?.contact_phone && <p className="m-sub text-ink-2">{studio.contact_phone}</p>}
            </section>
          )}
        </>
      )}
    </MemberShell>
  );
}
