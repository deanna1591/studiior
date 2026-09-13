import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";
import { publishChallenge } from "../actions";
import ChallengeCover from "../cover";

export const dynamic = "force-dynamic";

type Participant = { member_id: string; name: string; progress: number; goal: number;
  completed_at: string | null; rank: number | null };
type Overview = {
  id: string; title: string; description: string | null; type: string; goal_value: number;
  status: string; starts_on: string; ends_on: string; join_deadline: string;
  leaderboard_enabled: boolean; reward_description: string | null; participants: Participant[];
  cover_image_url: string | null; cover_focus_x: number; cover_focus_y: number;
};

export default async function ChallengeOverview({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/challenges");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Challenge"><Denied what="Challenges" role={ctx.role} /></AppShell>;
  }

  const { data } = await supabase.rpc("challenge_overview", { p_challenge_id: params.id });
  const c = data as Overview | null;
  if (!c) return <AppShell {...shell} title="Challenge"><Empty>Challenge not found.</Empty></AppShell>;

  const done = c.participants.filter((p) => p.completed_at).length;

  return (
    <AppShell {...shell} title={c.title}>
      <Link href="/challenges" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">
        ← All challenges
      </Link>

      <div className="s-card mb-4 p-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="text-[13px] text-ink-2">
              {c.type === "streak" ? `${c.goal_value} weeks in a row` : `${c.goal_value} classes`}
              {" · "}{c.starts_on} → {c.ends_on} · join by {c.join_deadline}
            </p>
            {c.reward_description && <p className="mt-1 text-[13px] text-ink">Reward: {c.reward_description}</p>}
            <p className="mt-1 text-[12px] text-ink-3">
              {c.leaderboard_enabled ? "Leaderboard on" : "Leaderboard off"}
            </p>
          </div>
          <span className="s-tag">{c.status}</span>
        </div>

        {c.status === "draft" && (
          <form action={publishChallenge} className="mt-3">
            <input type="hidden" name="challenge_id" value={c.id} />
            <button className="rounded-full bg-ink px-4 py-2 text-[13px] font-semibold text-surface">
              Publish
            </button>
            <span className="ml-2 text-[12px] text-ink-3">
              Members can see and join it, and everyone is emailed the invite.
            </span>
          </form>
        )}
      </div>

      <section className="mb-6">
        <SectionLabel>Cover photo</SectionLabel>
        <div className="mt-2">
          <ChallengeCover challengeId={c.id} coverUrl={c.cover_image_url}
                          focusX={c.cover_focus_x} focusY={c.cover_focus_y} />
        </div>
      </section>

      <p className="mb-2 text-[13px] text-ink-2">
        <span className="num font-semibold text-ink">{c.participants.length}</span> joined
        {" · "}<span className="num font-semibold text-ink">{done}</span> completed
      </p>

      {c.participants.length === 0 ? (
        <Empty>Nobody has joined yet.</Empty>
      ) : (
        <ul className="s-card divide-y divide-line overflow-hidden">
          {c.participants.map((p) => (
            <li key={p.member_id} className="flex items-center justify-between gap-3 px-4 py-3">
              <span className="flex items-center gap-2">
                {c.leaderboard_enabled && p.rank && (
                  <span className="num w-6 text-[12px] text-ink-3">#{p.rank}</span>
                )}
                <span className="text-[14px] text-ink">{p.name}</span>
              </span>
              <span className="flex items-center gap-3">
                <span className="num text-[13px] text-ink-2">{p.progress} / {p.goal}</span>
                {p.completed_at
                  ? <span className="s-tag" style={{ background: "var(--lime-tint)" }}>done</span>
                  : <span className="text-[12px] text-ink-3">in progress</span>}
              </span>
            </li>
          ))}
        </ul>
      )}
    </AppShell>
  );
}
