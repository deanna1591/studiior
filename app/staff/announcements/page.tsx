import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";

export const dynamic = "force-dynamic";

type Ann = { id: string; title: string; status: string; audience: string; pinned: boolean;
  starts_at: string; ends_at: string | null; notified_at: string | null };

export default async function Announcements() {
  const screen = await staffScreen("/announcements");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="What’s on"><Denied what="Announcements" role={ctx.role} /></AppShell>;

  const { data } = await supabase.rpc("staff_announcements", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as Ann[];
  const now = Date.now();
  const live = rows.filter((a) => a.status === "published"
    && new Date(a.starts_at).getTime() <= now && (!a.ends_at || new Date(a.ends_at).getTime() > now));
  const drafts = rows.filter((a) => a.status === "draft");
  const other = rows.filter((a) => !live.includes(a) && !drafts.includes(a));

  const dateWord = (iso: string) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" }).format(new Date(iso));
  const audienceWord = (a: string) => a === "both" ? "Members + instructors" : a === "instructors" ? "Instructors" : "Members";

  const Row = ({ a }: { a: Ann }) => (
    <li>
      <Link href={`/announcements/${a.id}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-paper">
        <span className="min-w-0">
          <span className="text-[14px] text-ink">{a.pinned ? "📌 " : ""}{a.title}</span>
          <span className="block text-[12px] text-ink-3">
            {audienceWord(a.audience)} · {dateWord(a.starts_at)}{a.ends_at ? `–${dateWord(a.ends_at)}` : ""}
            {a.notified_at ? " · emailed" : ""}
          </span>
        </span>
        <span className="s-tag">{a.status}</span>
      </Link>
    </li>
  );

  return (
    <AppShell {...shell} title="What’s on"
      actions={<Link href="/announcements/new" className="rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-surface">New announcement</Link>}>
      <p className="mb-4 max-w-2xl text-[13px] text-ink-2">
        Post something for your members — a workshop, a closure, a new instructor, an event.
        Members see published ones on their Home; it is one-way, no replies.
      </p>

      {rows.length === 0 ? (
        <Empty>Nothing posted yet. Create your first — members see it as soon as you publish.</Empty>
      ) : (
        <>
          {live.length > 0 && <><SectionLabel>Live</SectionLabel><ul className="s-card mb-6 divide-y divide-line overflow-hidden">{live.map((a) => <Row key={a.id} a={a} />)}</ul></>}
          {drafts.length > 0 && <><SectionLabel>Drafts</SectionLabel><ul className="s-card mb-6 divide-y divide-line overflow-hidden">{drafts.map((a) => <Row key={a.id} a={a} />)}</ul></>}
          {other.length > 0 && <><SectionLabel>Scheduled or ended</SectionLabel><ul className="s-card divide-y divide-line overflow-hidden">{other.map((a) => <Row key={a.id} a={a} />)}</ul></>}
        </>
      )}
    </AppShell>
  );
}
