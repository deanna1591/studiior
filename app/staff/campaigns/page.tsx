import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { fmtClock } from "@/lib/time";
import { AppShell, Denied, Empty } from "@/components/ui";
import { StateChip } from "@/components/state-chip";
import { createCampaign } from "./actions";

export const dynamic = "force-dynamic";

/**
 * Decision 50 — the studio's email campaigns.
 *
 * Manager-up, like Sales: front desk and instructors never see Campaigns (a
 * campaign writes to members and is a selling decision). Every row's counts
 * come from the linked notifications via campaign_status; the list itself shows
 * the stored recipient_count and status.
 */
type Row = {
  id: string; subject: string; status: string;
  recipient_count: number; scheduled_for: string | null; sent_at: string | null;
  created_at: string;
};

export default async function Campaigns() {
  const screen = await staffScreen("/campaigns");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Campaigns"><Denied what="campaigns" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase
    .from("campaigns")
    .select("id, subject, status, recipient_count, scheduled_for, sent_at, created_at")
    .order("created_at", { ascending: false });
  const rows = (data ?? []) as Row[];

  const when = (iso: string | null) => {
    if (!iso) return null;
    const d = new Intl.DateTimeFormat("en-GB",
      { timeZone: ctx.timeZone, day: "numeric", month: "short", year: "numeric" })
      .format(new Date(iso));
    return `${d} · ${fmtClock(iso, ctx.timeZone, ctx.timeFormat)}`;
  };

  return (
    <AppShell {...shell} title="Campaigns"
      actions={
        <form action={createCampaign}>
          <button type="submit"
            className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
            New campaign
          </button>
        </form>
      }>
      <p className="mb-5 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        Write one email and send it to a filtered group of members. Only members
        who said yes to news ever receive it, and every email carries a one-tap
        unsubscribe — it never touches their booking or reminder mail.
      </p>

      {rows.length === 0 ? (
        <Empty>No campaigns yet. “New campaign” writes one.</Empty>
      ) : (
        <ul className="divide-y divide-line rounded border border-line bg-surface">
          {rows.map((r) => (
            <li key={r.id}>
              <Link href={`/campaigns/${r.id}`}
                className="flex items-baseline gap-3 px-3.5 py-3 hover:bg-paper">
                <span className="min-w-0 flex-1">
                  <span className="text-[14px] leading-5 text-ink">
                    {r.subject || <span className="text-ink-3">Untitled</span>}
                  </span>
                  <span className="mt-0.5 block text-[12px] leading-4 text-ink-3">
                    {r.status === "sent" && r.sent_at
                      ? `Sent ${when(r.sent_at)} · ${r.recipient_count} recipient${r.recipient_count === 1 ? "" : "s"}`
                      : r.status === "scheduled" && r.scheduled_for
                        ? `Scheduled ${when(r.scheduled_for)} · ${r.recipient_count} recipient${r.recipient_count === 1 ? "" : "s"}`
                        : r.status === "sending"
                          ? `Sending · ${r.recipient_count} recipient${r.recipient_count === 1 ? "" : "s"}`
                          : "Draft"}
                  </span>
                </span>
                <StateChip state={r.status} />
              </Link>
            </li>
          ))}
        </ul>
      )}
    </AppShell>
  );
}
