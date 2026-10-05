import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import PurchasePoll from "./poll";

export const dynamic = "force-dynamic";

/** Decision 40: the member returns here from Xendit's hosted checkout. The
 *  callback grants the plan; this screen waits for the purchase to flip. */
export default async function Purchase({ params }: { params: { id: string } }) {
  const { supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data: purchase } = await supabase
    .from("xendit_purchases").select("status, product_order_id").eq("id", params.id).maybeSingle();
  const kind = purchase?.product_order_id ? "product" : "plan";

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href={kind === "product" ? "/shop" : "/account/plan"}
            className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> {kind === "product" ? "Shop" : "Plans"}
      </Link>
      <h1 className="m-title mb-4 text-ink">Your payment</h1>
      {purchase ? (
        <PurchasePoll id={params.id} initialStatus={purchase.status} kind={kind} />
      ) : (
        <div className="m-card p-5 text-center">
          <p className="text-[16px] font-semibold text-ink">We couldn’t find that payment</p>
          <p className="m-sub mt-1 text-ink-2">It may belong to a different account.</p>
          <Link href="/account/plan" className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
            Back to plans
          </Link>
        </div>
      )}
    </MemberShell>
  );
}
