import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { ActionForm, QuietButton } from "@/components/member/ui";
import { joinChallenge } from "./actions";
import { fmtDayLong } from "@/lib/time";

// A challenge date is a wall-calendar date; parse and format it AS UTC so it
// round-trips (this project's most repeated date bug otherwise).
const dayWord = (iso: string) => fmtDayLong(`${iso}T00:00:00Z`, "UTC");

export const dynamic = "force-dynamic";

type MChallenge = {
  id: string; title: string; type: string; goal_value: number; status: string;
  starts_on: string; ends_on: string; join_deadline: string; reward_description: string | null;
  joined: boolean; progress: number; completed: boolean; can_join: boolean;
};

const goalWord = (t: string, g: number) => (t === "streak" ? `${g} weeks in a row` : `${g} classes`);

/**
 * Challenges the member can see — the ones they have joined first, then open
 * ones to join. A studio with none has nothing here and no way to reach this
 * screen; the feature is simply absent for it.
 */
export default async function MemberChallenges() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase.rpc("member_challenges", { p_studio_id: ctx.studioId });
  const rows = (data ?? []) as MChallenge[];
  const mine = rows.filter((c) => c.joined);
  const open = rows.filter((c) => !c.joined && c.can_join);
  // Running (or upcoming) but the join deadline has passed: visible, not
  // joinable. The deadline governs joining, not visibility — a studio running a
  // challenge the app hides looks broken. Ended ones nobody joined stay hidden.
  const closed = rows.filter((c) => !c.joined && !c.can_join && (c.status === "active" || c.status === "scheduled"));

  const Ring = ({ c }: { c: MChallenge }) => {
    const pct = Math.min(100, Math.round((c.progress / Math.max(1, c.goal_value)) * 100));
    return (
      <div className="mt-2 h-2 w-full overflow-hidden rounded-full" style={{ background: "var(--accent-chip)" }}>
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: "var(--accent-solid)" }} />
      </div>
    );
  };

  return (
    <MemberShell title="Challenges" openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      {mine.length === 0 && open.length === 0 && closed.length === 0 && (
        <div className="m-card p-5">
          <p className="m-sub text-ink-2">No challenges on right now. Your studio will add them.</p>
        </div>
      )}

      {mine.length > 0 && (
        <section className="mb-5">
          <h2 className="m-eyebrow mb-2.5 font-semibold text-ink">Yours</h2>
          <ul className="space-y-3">
            {mine.map((c) => (
              <li key={c.id}>
                <Link href={`/challenges/${c.id}`} className="m-card m-press block p-4">
                  <div className="flex items-start justify-between gap-3">
                    <p className="m-name text-ink">{c.title}</p>
                    {c.completed
                      ? <span className="m-micro rounded-full px-2 py-0.5" style={{ background: "var(--lime-tint)", color: "var(--lime-text)" }}>Done</span>
                      : <span className="m-micro text-ink-3">{goalWord(c.type, c.goal_value)}</span>}
                  </div>
                  <p className="m-subtle mt-0.5 text-ink-3">
                    <span className="num font-semibold text-ink">{c.progress}</span> of{" "}
                    <span className="num">{c.goal_value}</span>
                    {c.type === "streak" ? " weeks" : " classes"}
                  </p>
                  <Ring c={c} />
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      {open.length > 0 && (
        <section>
          <h2 className="m-eyebrow mb-2.5 font-semibold text-ink">Open to join</h2>
          <ul className="space-y-3">
            {open.map((c) => (
              <li key={c.id} className="m-card p-4">
                <Link href={`/challenges/${c.id}`} className="block">
                  <p className="m-name text-ink">{c.title}</p>
                  <p className="m-subtle mt-0.5 text-ink-3">
                    {goalWord(c.type, c.goal_value)} · join by {dayWord(c.join_deadline)}
                  </p>
                  {c.reward_description && (
                    <p className="m-subtle mt-1 text-ink-2">Reward: {c.reward_description}</p>
                  )}
                </Link>
                <ActionForm action={joinChallenge} className="mt-3">
                  <input type="hidden" name="challenge_id" value={c.id} />
                  <QuietButton>Join</QuietButton>
                </ActionForm>
              </li>
            ))}
          </ul>
        </section>
      )}

      {closed.length > 0 && (
        <section className={open.length > 0 ? "mt-5" : ""}>
          <h2 className="m-eyebrow mb-2.5 font-semibold text-ink">Running</h2>
          <ul className="space-y-3">
            {closed.map((c) => (
              <li key={c.id}>
                <Link href={`/challenges/${c.id}`} className="m-card m-press block p-4">
                  <p className="m-name text-ink">{c.title}</p>
                  <p className="m-subtle mt-0.5 text-ink-3">
                    {goalWord(c.type, c.goal_value)}
                  </p>
                  <p className="m-micro mt-1 text-ink-2">
                    {c.status === "scheduled"
                      ? `Starts ${dayWord(c.starts_on)}`
                      : `Started ${dayWord(c.starts_on)} · joining closed`}
                  </p>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}
    </MemberShell>
  );
}
