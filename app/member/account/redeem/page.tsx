import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import RedeemForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Decision 110: redeem a gift code into gift credit. The full amount is applied
 * at checkout before any payment and never expires.
 */
export default async function Redeem() {
  const { studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();
  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Account
      </Link>
      <h1 className="m-title mb-2 text-ink">Redeem a gift card</h1>
      <p className="m-sub mb-4 text-ink-2">
        Enter the code from your gift card. The full amount becomes credit on your account,
        used at checkout before any payment. It never expires.
      </p>
      <RedeemForm />
    </MemberShell>
  );
}
