import Link from "next/link";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import { InviteEveryone, InviteOne } from "./panel";

export const dynamic = "force-dynamic";

type Row = {
  m_id: string; full_name: string; m_email: string;
  state: "claimed" | "invited" | "expired" | "never_invited" | "no_email";
  invited_at: string | null; expires_at: string | null;
};

const GROUPS = [
  { key: "never_invited", head: "Never invited",
    note: "They can be booked in and checked in; they just cannot sign in themselves." },
  { key: "expired", head: "Invite expired",
    note: "The link has run out. Sending another replaces it." },
  { key: "invited", head: "Invited, not claimed yet",
    note: "The email has gone. Resending supersedes the old link." },
  { key: "no_email", head: "No email address",
    note: "There is nowhere to send an invite. Add an address to their record first." },
  { key: "claimed", head: "Has an account", note: null },
] as const;

/**
 * Who has been asked, who has answered, and who has never been asked.
 *
 * The last group is the one that matters: before this screen there was no way
 * to know it existed, because an invite was a link an operator pasted into
 * their own mail client and nothing recorded that they had.
 */
export default async function Invites() {
  const screen = await staffScreen("/members/invites");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!["owner", "manager", "front_desk"].includes(ctx.role)) {
    return (
      <AppShell {...shell} title="Invites">
        <Denied what="Inviting members" role={ctx.role} />
      </AppShell>
    );
  }

  const { data, error } = await supabase.rpc("member_invite_status", {
    p_studio_id: ctx.studioId,
  });
  if (error) {
    return (
      <AppShell {...shell} title="Invites">
        <div className="max-w-[62ch] border-l-[3px] px-3.5 py-3" role="alert"
             style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <p className="text-[13px] leading-[19px] text-ink">
            The invite list could not be read, so this is not an empty studio — it
            is a failure.
          </p>
          <p className="num mt-2 text-[12px] leading-[17px] text-ink-2">{error.message}</p>
        </div>
      </AppShell>
    );
  }

  const rows = (data ?? []) as unknown as Row[];
  const by = (k: string) => rows.filter((r) => r.state === k);
  const invitable = rows.filter((r) => r.state === "never_invited" || r.state === "expired").length;
  const fmt = (d: string | null) =>
    d ? new Intl.DateTimeFormat("en-GB", {
          day: "numeric", month: "short", timeZone: ctx.timeZone }).format(new Date(d)) : "";

  return (
    <AppShell {...shell} title="Invites"
              actions={<NavLink href="/members">Back to members</NavLink>}>
      <p className="mb-4 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        An invite is an email from {ctx.studioName} with a link to set a password.
        There is nothing for anybody to download — the member app runs in their
        browser and they add it to their home screen from there.
      </p>

      <div className="mb-8"><InviteEveryone count={invitable} /></div>

      {GROUPS.map((g) => {
        const list = by(g.key);
        if (list.length === 0) return null;
        return (
          <section key={g.key} className="mb-8">
            <SectionLabel>{g.head} — {list.length}</SectionLabel>
            {g.note && (
              <p className="mt-1 max-w-[62ch] text-[12.5px] leading-[18px] text-ink-3">{g.note}</p>
            )}
            <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
              {list.map((r) => (
                <li key={r.m_id}
                    className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-3.5 py-2.5">
                  <div className="min-w-0">
                    <Link href={`/members/${r.m_id}`}
                          className="text-[14px] leading-5 text-ink hover:underline">
                      {r.full_name}
                    </Link>
                    <div className="truncate text-[12px] leading-4 text-ink-3">
                      {r.m_email || "no email address"}
                      {r.state === "invited" && r.expires_at &&
                        <> · sent {fmt(r.invited_at)}, expires {fmt(r.expires_at)}</>}
                      {r.state === "expired" && r.expires_at && <> · expired {fmt(r.expires_at)}</>}
                    </div>
                  </div>
                  {(r.state === "never_invited" || r.state === "expired" || r.state === "invited") && (
                    <InviteOne memberId={r.m_id}
                               label={r.state === "invited" ? "Resend" : "Send invite"}
                               quiet={r.state === "invited"} />
                  )}
                </li>
              ))}
            </ul>
          </section>
        );
      })}
    </AppShell>
  );
}
