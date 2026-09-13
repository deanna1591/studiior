import Link from "next/link";
import { notFound } from "next/navigation";
import { focalPoint } from "@/lib/focal";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { ActionForm, PrimaryButton } from "@/components/member/ui";
import { joinChallenge } from "../actions";
import { fmtDayLong } from "@/lib/time";
import { accentRamp, accentGradient, neutralAccent } from "@/lib/theme";

export const dynamic = "force-dynamic";

type Detail = {
  id: string; title: string; description: string | null; type: string; goal_value: number;
  status: string; starts_on: string; ends_on: string; join_deadline: string;
  reward_description: string | null; leaderboard_enabled: boolean;
  cover_image_url: string | null; cover_focus_x: number; cover_focus_y: number;
  joined: boolean; progress: number; completed_at: string | null; can_join: boolean;
  history: { occurred_at: string; class_name: string | null; instructor: string | null;
    counted: boolean; reason: string | null }[];
  leaderboard: { name: string; progress: number; rank: number | null; is_me: boolean }[] | null;
};

export default async function MemberChallengeDetail({ params }: { params: { id: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data } = await supabase.rpc("member_challenge_detail", { p_challenge_id: params.id });
  const c = data as Detail | null;
  if (!c) notFound();

  const unit = c.type === "streak" ? "weeks" : "classes";
  const pct = Math.min(100, Math.round((c.progress / Math.max(1, c.goal_value)) * 100));
  // From the reader, which respects the deadline: a running challenge past its
  // join date is visible but not joinable.
  const canJoin = c.can_join;
  const closedRunning = !c.joined && !c.can_join && (c.status === "active" || c.status === "scheduled");

  // The cover, or the accent gradient the member hero already falls back to.
  const [g1, g2] = accentGradient(accentRamp(accent ?? neutralAccent(preset), preset));
  const coverFallback = `linear-gradient(140deg, ${g1} 0%, ${g2} 100%)`;

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/challenges" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Challenges
      </Link>

      {/* The cover, above the title where they decide whether to join. Focal
          point so a wide photo is not cropped to a sixth of itself on a phone. */}
      <span className="m-hero mb-4 block" style={!c.cover_image_url ? { background: coverFallback } : undefined}>
        {c.cover_image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={c.cover_image_url} alt="" aria-hidden
               className="absolute inset-0 h-full w-full object-cover"
               style={{ objectPosition: focalPoint(c.cover_focus_x, c.cover_focus_y) }} />
        )}
      </span>

      <h1 className="m-title text-ink">{c.title}</h1>
      <p className="m-sub mt-1 text-ink-2">
        {c.type === "streak" ? `${c.goal_value} weeks in a row` : `${c.goal_value} classes`}
        {" · "}ends {fmtDayLong(`${c.ends_on}T00:00:00Z`, "UTC")}
      </p>
      {c.description && <p className="m-body mt-3 whitespace-pre-line text-ink-2">{c.description}</p>}

      {/* The member's own progress — always, whatever the leaderboard setting. */}
      {c.joined ? (
        <div className="m-card mt-4 p-4">
          <div className="flex items-baseline justify-between">
            <p className="m-eyebrow font-semibold text-ink">Your progress</p>
            {c.completed_at && (
              <span className="m-micro rounded-full px-2 py-0.5"
                    style={{ background: "var(--lime-tint)", color: "var(--lime-text)" }}>Completed</span>
            )}
          </div>
          <p className="num mt-1 text-[26px] font-bold leading-8 text-ink">
            {c.progress}<span className="text-[15px] font-medium text-ink-3"> / {c.goal_value} {unit}</span>
          </p>
          <div className="mt-2 h-2 w-full overflow-hidden rounded-full" style={{ background: "var(--accent-chip)" }}>
            <div className="h-full rounded-full" style={{ width: `${pct}%`, background: "var(--accent-solid)" }} />
          </div>
          {c.type === "streak" && !c.completed_at && (
            <p className="m-micro mt-1.5 text-ink-3">Your current run. Miss a week and it counts from your next class.</p>
          )}
        </div>
      ) : canJoin ? (
        <div className="m-card mt-4 p-4">
          {c.reward_description && <p className="m-sub mb-3 text-ink-2">Reward: {c.reward_description}</p>}
          <ActionForm action={joinChallenge}>
            <input type="hidden" name="challenge_id" value={c.id} />
            <PrimaryButton>Join this challenge</PrimaryButton>
            <p className="m-micro mt-1.5 text-center text-ink-3">
              Every class you have taken since {fmtDayLong(`${c.starts_on}T00:00:00Z`, "UTC")} counts.
            </p>
          </ActionForm>
        </div>
      ) : closedRunning ? (
        <div className="m-card mt-4 p-4">
          <p className="m-sub text-ink-2">
            {c.status === "scheduled"
              ? <>Starts {fmtDayLong(`${c.starts_on}T00:00:00Z`, "UTC")}.</>
              : <>Started {fmtDayLong(`${c.starts_on}T00:00:00Z`, "UTC")} — joining has closed.</>}
          </p>
          {c.reward_description && <p className="m-sub mt-1 text-ink-2">Reward: {c.reward_description}</p>}
        </div>
      ) : (
        <p className="m-sub mt-4 text-ink-2">This challenge has finished.</p>
      )}

      {c.reward_description && c.joined && (
        <p className="m-sub mt-4 text-ink-2">Reward: {c.reward_description}</p>
      )}

      {/* The board only if the studio turned it on. */}
      {c.leaderboard_enabled && c.leaderboard && c.leaderboard.length > 0 && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">Leaderboard</h2>
          <ul className="m-card mt-2 divide-y divide-line overflow-hidden">
            {c.leaderboard.slice(0, 20).map((p, i) => (
              <li key={i} className="flex items-center justify-between gap-3 px-4 py-2.5"
                  style={p.is_me ? { background: "var(--accent-chip)" } : undefined}>
                <span className="flex items-center gap-2">
                  <span className="num w-6 text-[12px] text-ink-3">#{p.rank ?? i + 1}</span>
                  <span className="m-body text-ink">{p.name}{p.is_me && " (you)"}</span>
                </span>
                <span className="num text-[13px] text-ink-2">{p.progress}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {c.joined && c.history.length > 0 && (
        <section className="mt-6">
          <h2 className="section-label text-ink-2">Your classes</h2>
          <ul className="m-card mt-2 divide-y divide-line overflow-hidden">
            {c.history.map((h, i) => (
              <li key={i} className="flex items-start justify-between gap-3 px-4 py-2.5">
                <span className="min-w-0">
                  <span className="m-body block truncate text-ink">{h.class_name ?? "Class"}</span>
                  <span className="m-micro block text-ink-3">
                    {fmtDayLong(h.occurred_at, ctx.timeZone)}{h.instructor ? ` · ${h.instructor}` : ""}
                  </span>
                </span>
                {h.counted ? (
                  <span className="m-micro shrink-0 font-semibold" style={{ color: "var(--lime-text)" }}>
                    Counted
                  </span>
                ) : (
                  // Why it did not count, so the number is trusted rather than
                  // argued with — a late cancel or a no-show in the window.
                  <span className="m-micro max-w-[9rem] shrink-0 text-right leading-[15px] text-ink-2">
                    Didn&rsquo;t count · {h.reason}
                  </span>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
    </MemberShell>
  );
}
