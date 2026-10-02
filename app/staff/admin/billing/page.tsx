import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AdminShell, Empty, NavLink } from "@/components/ui";
import { signOut } from "../../actions";
import ExtendForm from "./form";
import CompForm from "./comp";

export const dynamic = "force-dynamic";

/**
 * Every studio's billing state, for the operator.
 *
 * Platform admin only. Built on the /admin frame — createClient + getUser +
 * is_platform_admin + AdminShell — NOT staffScreen(): a platform operator may be
 * staff of no studio, and staffScreen() redirects such a login away, so the
 * "Studio billing" link used to loop back to /admin for exactly the person it is
 * for. The real boundary is platform_subs_studio_read (a studio sees its own
 * row, a platform admin sees all), so this screen is what that policy returns.
 */
export default async function AdminBilling() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: isAdmin } = await supabase.rpc("is_platform_admin");
  const signOutControl = (
    <form action={signOut}>
      <button className="text-[12px] leading-4 text-ink-3 underline underline-offset-4 hover:text-ink">
        Sign out
      </button>
    </form>
  );
  if (!isAdmin) {
    return (
      <AdminShell email={user.email ?? ""} title="Not available" signOut={signOutControl}
                  actions={<NavLink href="/admin">Back to admin</NavLink>}>
        <Empty>This is the operator&rsquo;s screen, and you are not one.</Empty>
      </AdminShell>
    );
  }

  const { data: subs } = await supabase
    .from("platform_subscriptions")
    .select("studio_id, status, trial_ends_at, grace_ends_at, locked_at, comp_note, comp_set_at, stripe_subscription_id, studios(name, slug)")
    .order("status");

  const day = (iso: string | null) =>
    iso ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" })
            .format(new Date(iso)) : "—";

  return (
    <AdminShell email={user.email ?? ""} title="Studio billing" signOut={signOutControl}
                actions={<NavLink href="/admin">Back to admin</NavLink>}>
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-3">Every studio</h2>
      {(subs ?? []).length === 0 ? (
        <Empty>No studios yet.</Empty>
      ) : (
        <div className="divide-y divide-line border-y border-line bg-surface">
          {(subs ?? []).map((s) => {
            const comp = s.status === "complimentary";
            return (
              <div key={s.studio_id} className="flex items-start justify-between gap-4 px-3 py-2.5">
                <span className="min-w-0">
                  <span className="block truncate text-[13px] leading-[18px] text-ink">
                    {s.studios?.name ?? s.studio_id}
                  </span>
                  <span className="block text-[11px] leading-4 text-ink-3">
                    {s.status.replace("_", " ")}
                    {comp && <> · since {day(s.comp_set_at)}{s.comp_note ? ` · ${s.comp_note}` : ""}</>}
                    {s.status === "trialing" && <> · trial to {day(s.trial_ends_at)}</>}
                    {s.status === "past_due" && <> · locks {day(s.grace_ends_at)}</>}
                    {s.status === "locked" && <> · since {day(s.locked_at)}</>}
                    {!comp && (s.stripe_subscription_id ? " · card on file" : " · no card")}
                  </span>
                </span>
                <span className="flex shrink-0 items-center gap-2">
                  {!comp && <ExtendForm studioId={s.studio_id} />}
                  <CompForm studioId={s.studio_id} isComplimentary={comp} />
                </span>
              </div>
            );
          })}
        </div>
      )}
    </AdminShell>
  );
}
