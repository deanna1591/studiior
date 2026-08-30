import { Shell, NavLink } from "@/components/ui";
import { getStaffAccess, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import StripeStub from "./stub";

export const dynamic = "force-dynamic";

/** Stub. No OAuth, no keys, no webhooks — a description and a way past it. */
export default async function StripePage() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = access.ctx;

  return (
    <Shell title="Connect Stripe" subtitle="Coming soon"
           right={<NavLink href="/">Back to dashboard</NavLink>}>
      <div className="max-w-xl space-y-4 text-sm leading-relaxed text-stone-700">
        <p className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-amber-900">
          Not built yet. Nothing on this page charges anyone or talks to Stripe.
        </p>
        <p>
          When it lands, you will connect your <strong>own</strong> Stripe account
          through Stripe Connect. Payments go directly to you — money never passes
          through Studiior, and we never hold your funds.
        </p>
        <p>Once connected you will be able to:</p>
        <ul className="list-disc space-y-1 pl-5">
          <li>Sell memberships and class packs, with cards charged on your account</li>
          <li>Take drop-in payments at the front desk</li>
          <li>Bill recurring plans automatically at each period</li>
          <li>Refund from the payment record, without leaving Studiior</li>
        </ul>
        <p className="text-stone-600">
          Until then you can run the studio exactly as you do now and record
          payments however you already do. Nothing else is blocked by this.
        </p>
        {isManagerUp(ctx.role) && <StripeStub />}
      </div>
    </Shell>
  );
}
