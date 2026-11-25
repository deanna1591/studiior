import Link from "next/link";
import { accentSolid } from "@/lib/accent-pair";
import { buyStudio } from "@/lib/buy-plans";
import BuyFrame from "../../frame";

export const dynamic = "force-dynamic";

/** Decision 118: where Xendit returns a buyer without an account. */
export default async function Paid({ params }: { params: { plan: string } }) {
  const studio = await buyStudio();
  const plan = studio?.plans.find((p) => p.id === params.plan);
  const name = plan?.name ?? "plan";
  return (
    <BuyFrame studio={studio} title="Thank you">
      <section className="m-card p-5">
        <p className="m-body text-ink">
          Your {name} is paid. Check your email to set up your account and start booking.
        </p>
        <p className="m-sub mt-3 text-ink-2">
          Your plan starts on the day you set up your account. Use the email address you paid with.
        </p>
        <div className="mt-5 space-y-3">
          <Link href="/signup" className="m-action m-press flex w-full items-center justify-center rounded-xl text-[16px] font-semibold"
                style={accentSolid()}>
            Set up my account
          </Link>
          <Link href="/login" className="m-action m-press flex w-full items-center justify-center rounded-xl border border-line-2 bg-surface text-[16px] font-semibold text-ink">
            I already have an account
          </Link>
        </div>
      </section>
    </BuyFrame>
  );
}
