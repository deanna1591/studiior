import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { Shell, NavLink } from "@/components/ui";
import ProvisionForm from "./form";

export const dynamic = "force-dynamic";

export default async function AdminPage({
  searchParams,
}: {
  searchParams: { token?: string; studio?: string };
}) {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  // The route check and the real permission are the same question asked of the
  // same source: platform_admins. provision_studio() asks it again on every
  // call, so reaching this page by other means achieves nothing.
  const { data: isAdmin } = await supabase.rpc("is_platform_admin");
  if (!isAdmin) {
    const ctx = await getStaffContext();
    return (
      <Shell title="Not available" subtitle={user.email ?? ""}
             right={<NavLink href={ctx ? "/" : "/login"}>Back</NavLink>}>
        <p className="text-sm text-ink-2">
          This page provisions new studios and is limited to platform operators.
        </p>
      </Shell>
    );
  }

  const { data: studios } = await supabase
    .from("studios")
    .select("id, name, slug, status, timezone, currency, created_at")
    .order("created_at", { ascending: false });

  const { data: invites } = await supabase
    .from("studio_invites")
    .select("id, studio_id, email, expires_at, accepted_at")
    .order("created_at", { ascending: false });

  const inviteFor = new Map((invites ?? []).map((i) => [i.studio_id, i]));
  const justCreated = searchParams.studio
    ? (studios ?? []).find((s) => s.id === searchParams.studio)
    : undefined;

  return (
    <Shell
      title="Provision a studio"
      subtitle={`Platform operator · ${user.email}`}
      right={<NavLink href="/">Back to app</NavLink>}
    >
      {searchParams.token && justCreated && (
        <div className="mb-6 rounded border border-lime-text bg-lime-tint p-4">
          <p className="text-sm font-medium text-ink">
            {justCreated.name} created. Send this link to the owner:
          </p>
          <code className="mt-2 block break-all rounded border border-lime-text bg-white px-3 py-2 font-mono text-xs">
            {process.env.NEXT_PUBLIC_STAFF_ORIGIN ?? "http://localhost:3000"}/invite/{searchParams.token}
          </code>
          <p className="mt-2 text-xs leading-relaxed text-ink">
            This is the only time the token is readable. Only its hash is stored,
            so if the link is lost the studio needs a fresh invite rather than a
            lookup.
          </p>
        </div>
      )}

      <ProvisionForm />

      <h2 className="mb-2 mt-10 text-sm font-semibold uppercase tracking-wide text-ink-3">
        Studios
      </h2>
      <ul className="divide-y divide-line rounded border border-line bg-white">
        {(studios ?? []).map((s) => {
          const inv = inviteFor.get(s.id);
          return (
            <li key={s.id} className="flex items-center justify-between gap-4 px-3 py-2.5">
              <div>
                <div className="text-sm font-medium">{s.name}</div>
                <div className="text-xs text-ink-3">
                  {s.slug} · {s.timezone} · {s.currency}
                </div>
              </div>
              <div className="text-right text-xs">
                <div className={s.status === "provisioning" ? "text-ink-2" : "text-ink-2"}>
                  {s.status}
                </div>
                {inv && (
                  <div className="text-ink-3">
                    {inv.accepted_at
                      ? "invite accepted"
                      : new Date(inv.expires_at) < new Date()
                        ? "invite expired"
                        : `invite pending · ${inv.email}`}
                  </div>
                )}
              </div>
            </li>
          );
        })}
        {(studios ?? []).length === 0 && (
          <li className="px-3 py-3 text-sm text-ink-3">No studios yet.</li>
        )}
      </ul>
    </Shell>
  );
}
