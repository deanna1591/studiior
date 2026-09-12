import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";

export const dynamic = "force-dynamic";

type ChallengeRow = {
  id: string; title: string; type: string; goal_value: number; status: string;
  starts_on: string; ends_on: string; join_deadline: string;
  leaderboard_enabled: boolean; joined_count: number; completed_count: number;
};

const GOAL = (t: string, g: number) =>
  t === "streak" ? `${g} weeks in a row` : `${g} classes`;

export default async function ChallengesList() {
  const screen = await staffScreen("/challenges");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Permissions §9 / Decision 10: challenges are managed by owners and managers.
  // challenges_manager_write is the boundary; the rail hides the link for
  // everyone else and a manager reaching it by URL gets a real screen.
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Challenges"><Denied what="Challenges" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.rpc("staff_challenges", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as ChallengeRow[];
  const live = rows.filter((c) => c.status === "active" || c.status === "scheduled");
  const done = rows.filter((c) => c.status === "ended" || c.status === "archived");
  const drafts = rows.filter((c) => c.status === "draft");

  const Card = (c: ChallengeRow) => (
    <Link key={c.id} href={`/challenges/${c.id}`} className="s-card block p-4 hover:bg-paper">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="s-head truncate">{c.title}</p>
          <p className="mt-0.5 text-[12px] text-ink-2">
            {GOAL(c.type, c.goal_value)} · {c.starts_on} → {c.ends_on}
          </p>
        </div>
        <span className="s-tag shrink-0">{c.status}</span>
      </div>
      <p className="mt-2 text-[12px] text-ink-2">
        <span className="num font-semibold text-ink">{c.joined_count}</span> joined
        {" · "}
        <span className="num font-semibold text-ink">{c.completed_count}</span> completed
        {c.leaderboard_enabled && <> · leaderboard on</>}
      </p>
    </Link>
  );

  return (
    <AppShell {...shell} title="Challenges">
      <div className="mb-4 flex items-center justify-between">
        <p className="max-w-[52ch] text-[13px] text-ink-2">
          Members opt in and their qualifying attendance counts from the start date.
          Recognition, not competition — the leaderboard is off unless you turn it on.
        </p>
        <Link href="/challenges/new"
              className="shrink-0 rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-surface">
          New challenge
        </Link>
      </div>

      {rows.length === 0 ? (
        <Empty>No challenges yet. Create one and members can join it in their app.</Empty>
      ) : (
        <div className="space-y-6">
          {drafts.length > 0 && (
            <section><SectionLabel>Drafts</SectionLabel>
              <div className="mt-2 space-y-2">{drafts.map(Card)}</div></section>
          )}
          {live.length > 0 && (
            <section><SectionLabel>Running and upcoming</SectionLabel>
              <div className="mt-2 space-y-2">{live.map(Card)}</div></section>
          )}
          {done.length > 0 && (
            <section><SectionLabel>Finished</SectionLabel>
              <div className="mt-2 space-y-2">{done.map(Card)}</div></section>
          )}
        </div>
      )}
    </AppShell>
  );
}
