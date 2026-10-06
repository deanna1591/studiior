import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { howYouPayCopy } from "@/lib/pay-copy";

export const dynamic = "force-dynamic";

/**
 * How you pay — the copy follows whether the studio has a LIVE online provider,
 * detected from the SAME flag the Buy pages use (settings.xenditEnabled), never
 * toggled here. With one, you can pay in the app (GCash/Maya/card) and still at
 * the desk; without one, the studio takes payment at the desk. Decision 16: the
 * provider is an adapter over the manual foundation.
 */
export default async function HowYouPay() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const providerConnected = settings.xenditEnabled;
  const copy = howYouPayCopy({ providerConnected, studioName });

  // Contact details for the "Questions about a payment?" card (unchanged).
  const { data: studio } = await supabase.from("studios")
    .select("contact_email, contact_phone").eq("id", ctx.studioId).maybeSingle();

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-4 text-ink">How you pay</h1>

      <section className="m-card p-4">
        <p className="m-eyebrow mb-1 font-semibold text-ink">{copy.title}</p>
        <p className="m-sub text-ink-2">{copy.body}</p>
      </section>

      {/* A connected card wallet (Stripe adapter) stays available where it
          exists and the app-checkout copy above is not already shown. */}
      {settings.hasPaymentProvider && !providerConnected && (
        <section className="m-card mt-4 p-4">
          <p className="m-eyebrow mb-1 font-semibold text-ink">Your cards</p>
          <p className="m-sub text-ink-2">
            Add a card when you book a class or buy a plan — it is saved for next
            time, and you can remove it from the checkout screen.
          </p>
        </section>
      )}

      {(studio?.contact_email || studio?.contact_phone) && (
        <section className="m-card mt-4 p-4">
          <p className="m-eyebrow mb-1 font-semibold text-ink">Questions about a payment?</p>
          {studio?.contact_email && <p className="m-sub text-ink-2">{studio.contact_email}</p>}
          {studio?.contact_phone && <p className="m-sub text-ink-2">{studio.contact_phone}</p>}
        </section>
      )}

      <Link href="/account/plan"
            className="m-press mt-4 inline-flex items-center gap-1 text-[13px] leading-[18px] text-ink-2 underline underline-offset-4">
        See plans <Icon name="chevron-right" size={14} />
      </Link>
    </MemberShell>
  );
}
