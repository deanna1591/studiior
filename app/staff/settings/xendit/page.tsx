import { AppShell, Empty, NavLink } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import { ConnectForm, ConnectedPanel } from "./form";

export const dynamic = "force-dynamic";

/**
 * Connect Xendit — the second online payment adapter (Decision 40, Part A).
 * Owner only, per §9: this is the studio's own Xendit account. The secrets are
 * encrypted at rest under an env-only key; this screen never shows them back.
 *
 * Xendit serves Philippine merchants where Stripe does not, so a studio takes
 * one-time online payments (packs, drop-ins) through its own Xendit account.
 */
export default async function XenditSettings() {
  const screen = await staffScreen("/settings/xendit");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (ctx.role !== "owner") {
    return (
      <AppShell {...shell} title="Xendit">
        <Empty>Connecting a payment account is the owner&rsquo;s to do. You are signed in as {ctx.role.replace("_", " ")}.</Empty>
      </AppShell>
    );
  }

  const { data: prov } = await supabase
    .from("studio_payment_providers")
    .select("key_last4, test_mode, last_verified_at")
    .eq("studio_id", ctx.studioId).eq("provider", "xendit").maybeSingle();

  // Pending purchases + why the last return-check did nothing, so staff can see
  // WHY a payment is stuck (Decision 40 amendment 9).
  const { data: pending } = await supabase
    .from("xendit_purchases")
    .select("id, amount_cents, currency, last_return_check_result, last_return_check_at, created_at")
    .eq("studio_id", ctx.studioId).eq("status", "pending")
    .order("created_at", { ascending: false }).limit(20);

  const staffOrigin = process.env.NEXT_PUBLIC_STAFF_ORIGIN ?? "https://app.studiior.com";
  const callbackUrl = `${staffOrigin}/api/xendit/callback`;

  return (
    <AppShell {...shell} title="Xendit" actions={<NavLink href="/settings">Back to settings</NavLink>}>
      <div className="max-w-xl space-y-4">
        {prov ? (
          <ConnectedPanel
            keyLast4={prov.key_last4}
            testMode={prov.test_mode}
            lastVerifiedAt={prov.last_verified_at}
            callbackUrl={callbackUrl}
            pending={(pending ?? []).map((p) => ({
              id: p.id,
              amountCents: p.amount_cents,
              currency: p.currency,
              lastResult: p.last_return_check_result,
              lastCheckAt: p.last_return_check_at,
            }))}
          />
        ) : (
          <>
            <p className="text-[14px] leading-[22px] text-ink">
              Connect your Xendit account to take one-time online payments — packs
              and drop-ins — from members in the app. Money is charged on your own
              Xendit account; it never passes through us.
            </p>
            <p className="text-[13px] leading-[20px] text-ink-2">
              You will need your Xendit <strong>secret API key</strong> and your{" "}
              <strong>webhook verification token</strong>. After connecting, paste
              the callback URL shown here into your Xendit webhook settings.
            </p>
            <ConnectForm />
          </>
        )}
        <p className="border-t border-line pt-4 text-[12px] leading-[18px] text-ink-3">
          Recurring memberships still bill at the desk for now — online auto-charge
          is a later step. Refunds are made from your Xendit dashboard and recorded
          here as an adjustment.
        </p>
      </div>
    </AppShell>
  );
}
