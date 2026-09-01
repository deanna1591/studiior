import { AppShell, Empty, NavLink, Rows, SectionLabel } from "@/components/ui";
import { staffScreen } from "@/lib/screen";
import ExtendForm from "./form";

export const dynamic = "force-dynamic";

/**
 * Every studio's billing state, for the operator.
 *
 * Platform admin only, checked in SQL: platform_subs_studio_read lets a studio
 * see its own row and a platform admin see all of them, so this screen is
 * simply what that policy returns. It does no filtering of its own and has no
 * way to leak one studio's billing to another.
 */
export default async function AdminBilling() {
  const screen = await staffScreen("/admin/billing");
  if (screen.gate) return screen.gate;
  const { supabase, shell } = screen;

  const { data: isAdmin } = await supabase.rpc("is_platform_admin");
  if (!isAdmin) {
    return (
      <AppShell {...shell} title="Billing">
        <Empty>This is the operator&rsquo;s screen, and you are not one.</Empty>
      </AppShell>
    );
  }

  const { data: subs } = await supabase
    .from("platform_subscriptions")
    .select("studio_id, status, trial_ends_at, grace_ends_at, locked_at, stripe_subscription_id, studios(name, slug)")
    .order("status");

  const day = (iso: string | null) =>
    iso ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" })
            .format(new Date(iso)) : "—";

  return (
    <AppShell {...shell} title="Studio billing"
              actions={<NavLink href="/admin">Back to admin</NavLink>}>
      <SectionLabel>Every studio</SectionLabel>
      {(subs ?? []).length === 0 ? (
        <Empty>No studios yet.</Empty>
      ) : (
        <Rows>
          {(subs ?? []).map((s) => (
            <div key={s.studio_id} className="flex items-start justify-between gap-4 px-3 py-2.5">
              <span className="min-w-0">
                <span className="block truncate text-[13px] leading-[18px] text-ink">
                  {s.studios?.name ?? s.studio_id}
                </span>
                <span className="block text-[11px] leading-4 text-ink-3">
                  {s.status.replace("_", " ")}
                  {s.status === "trialing" && <> · trial to {day(s.trial_ends_at)}</>}
                  {s.status === "past_due" && <> · locks {day(s.grace_ends_at)}</>}
                  {s.status === "locked" && <> · since {day(s.locked_at)}</>}
                  {s.stripe_subscription_id ? " · card on file" : " · no card"}
                </span>
              </span>
              <ExtendForm studioId={s.studio_id} />
            </div>
          ))}
        </Rows>
      )}
    </AppShell>
  );
}
