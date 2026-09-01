import { AppShell, Empty, NavLink, Notice } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import ConnectButton from "./form";

export const dynamic = "force-dynamic";

/**
 * Connect Stripe. Owner only, per §9 — this is the studio's bank relationship.
 *
 * Connect STANDARD: the studio authorises us against their own Stripe account
 * and keeps their own dashboard, their own payouts and their own dispute
 * handling. Money goes member -> studio directly, with no application fee and
 * no leg through Studiior, which is why nothing here mentions our balance.
 */
export default async function StripeSettings({
  searchParams,
}: {
  searchParams: { connected?: string; e?: string };
}) {
  const screen = await staffScreen("/settings/stripe");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (ctx.role !== "owner") {
    return (
      <AppShell {...shell} title="Payments">
        <Empty>
          Connecting a payment account is the owner&rsquo;s to do. You are signed
          in as {ctx.role.replace("_", " ")}.
        </Empty>
      </AppShell>
    );
  }

  const { data: studio } = await supabase
    .from("studios").select("stripe_account_id, currency").eq("id", ctx.studioId).maybeSingle();
  const connected = !!studio?.stripe_account_id;

  return (
    <AppShell {...shell} title="Payments" actions={<NavLink href="/">Back to schedule</NavLink>}>
      <div className="max-w-xl space-y-4">
        {searchParams.connected && <Notice kind="ok">Stripe is connected. You can sell plans now.</Notice>}
        {searchParams.e && <Notice kind="error">{searchParams.e}</Notice>}

        {connected ? (
          <>
            <p className="text-[14px] leading-[22px] text-ink">
              Connected to Stripe account{" "}
              <span className="font-mono text-[13px]">{studio!.stripe_account_id}</span>.
            </p>
            <p className="text-[13px] leading-[20px] text-ink-2">
              Members pay you directly. Payouts, refunds and disputes are in your
              own Stripe dashboard, and we take no cut of a class.
            </p>
          </>
        ) : (
          <>
            <p className="text-[14px] leading-[22px] text-ink">
              Connect your own Stripe account to sell memberships, packs and
              drop-ins. Cards are charged on your account and the money is yours
              from the moment it lands — it never passes through us.
            </p>
            <p className="text-[13px] leading-[20px] text-ink-2">
              You will need your business details and a bank account. Stripe asks
              for those, not us; we only ever see that the account is connected.
            </p>
            <ConnectButton />
          </>
        )}

        <p className="border-t border-line pt-4 text-[12px] leading-[18px] text-ink-3">
          Test mode. Nothing here moves real money yet.
        </p>
      </div>
    </AppShell>
  );
}
