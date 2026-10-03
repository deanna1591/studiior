import Link from "next/link";
import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { fmtClock } from "@/lib/time";
import { AppShell, Denied } from "@/components/ui";
import { StateChip } from "@/components/state-chip";
import Editor from "../editor";
import CampaignControls from "../campaign-controls";
import type { AudienceFilter } from "../actions";

export const dynamic = "force-dynamic";

type Campaign = {
  id: string; studio_id: string; subject: string; body: string;
  audience: AudienceFilter; status: string;
  scheduled_for: string | null; sent_at: string | null; recipient_count: number;
};

export default async function CampaignPage({ params }: { params: { id: string } }) {
  const screen = await staffScreen(`/campaigns/${params.id}`);
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Campaign"><Denied what="campaigns" role={ctx.role} /></AppShell>;
  }

  const { data: c } = await supabase
    .from("campaigns")
    .select("id, studio_id, subject, body, audience, status, scheduled_for, sent_at, recipient_count")
    .eq("id", params.id)
    .maybeSingle();
  if (!c) notFound();
  const campaign = c as Campaign;

  const [{ data: studio }, { data: status }] = await Promise.all([
    supabase.from("studios").select("name").eq("id", campaign.studio_id).maybeSingle(),
    // Flips a finished 'sending' campaign to 'sent' and returns live counts.
    supabase.rpc("campaign_status", { p_campaign_id: campaign.id }),
  ]);
  const studioName = studio?.name ?? "the studio";
  const st = (status ?? {}) as { status?: string; sent?: number; failed?: number; pending?: number };
  const current = st.status ?? campaign.status;

  const when = (iso: string | null) => {
    if (!iso) return null;
    const d = new Intl.DateTimeFormat("en-GB",
      { timeZone: ctx.timeZone, day: "numeric", month: "short", year: "numeric" })
      .format(new Date(iso));
    return `${d} · ${fmtClock(iso, ctx.timeZone, ctx.timeFormat)}`;
  };

  // A draft is composed; everything else is read-only.
  if (current === "draft") {
    return (
      <AppShell {...shell} title="Campaign"
        actions={<Link href="/campaigns" className="text-[13px] text-ink-2 underline underline-offset-4">All campaigns</Link>}>
        <Editor
          id={campaign.id}
          initialSubject={campaign.subject}
          initialBody={campaign.body}
          initialFilter={campaign.audience ?? {}}
          studioName={studioName}
          timeZone={ctx.timeZone}
        />
      </AppShell>
    );
  }

  const paras = (campaign.body ?? "").split(/\n\n+/).filter((p) => p.trim().length > 0);

  return (
    <AppShell {...shell} title="Campaign"
      actions={<Link href="/campaigns" className="text-[13px] text-ink-2 underline underline-offset-4">All campaigns</Link>}>
      <div className="mb-4 flex items-center gap-3">
        <StateChip state={current} />
        <span className="text-[13px] text-ink-2">
          {current === "scheduled" && campaign.scheduled_for
            ? `Scheduled for ${when(campaign.scheduled_for)} · ${campaign.recipient_count} recipient${campaign.recipient_count === 1 ? "" : "s"}`
            : current === "sent"
              ? `Sent ${when(campaign.sent_at)} · ${st.sent ?? 0} delivered${(st.failed ?? 0) > 0 ? `, ${st.failed} failed` : ""}${(st.pending ?? 0) > 0 ? `, ${st.pending} pending` : ""}`
              : current === "sending"
                ? `Sending · ${st.sent ?? 0} of ${campaign.recipient_count} done`
                : "Cancelled"}
        </span>
      </div>

      <div className="max-w-[560px] rounded-lg border border-line bg-surface p-5">
        <div className="mb-3 text-[17px] font-semibold text-ink">{studioName}</div>
        <div className="mb-4 h-[3px] w-11 rounded bg-accent-solid" />
        <p className="text-[15px] font-semibold text-ink">{campaign.subject}</p>
        <div className="mt-3 space-y-3 text-[14px] leading-[21px] text-ink">
          {paras.map((p, i) => <p key={i}>{p}</p>)}
        </div>
        <p className="mt-6 border-t border-line pt-3 text-[12px] leading-4 text-ink-3">
          You’re receiving this because you said yes to news from {studioName}.{" "}
          <span className="underline">Unsubscribe</span>
        </p>
      </div>

      <CampaignControls id={campaign.id} canCancel={current === "scheduled"} />
    </AppShell>
  );
}
