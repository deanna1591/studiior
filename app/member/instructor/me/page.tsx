import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { SignOut } from "@/components/member/sign-out";
import { CalendarFeedControl } from "@/components/member/calendar-feed";
import { mintFeed, revokeFeed } from "@/lib/feed-actions";

export const dynamic = "force-dynamic";

type Rec = {
  classes_taught: number; this_month: number; week_streak: number;
  first_class_on: string | null; state: string; empty_hint: string;
  not_a_leaderboard: string;
};

/**
 * ME — Decision 10's recognition, and the account.
 *
 * Classes taught, this month, and a weekly streak. NOT a leaderboard and not a
 * comparison: §12 note 20 is explicit that analytics for an instructor is a
 * coaching tool, and Decision 10 adds a personal count rather than a ranking.
 * The screen says so out loud, because a number about yourself next to no
 * context is the sort of thing people assume is being compared.
 *
 * Decision 5: the streak is WEEKLY, not daily. A studio's timetable does not
 * run every day and a daily streak would punish an instructor for the shape of
 * the rota.
 */
export default async function MePage() {
  const { ctx, supabase } = await instructorScreen();
  const [{ data }, { data: relData }, { data: feed }] = await Promise.all([
    supabase.rpc("instructor_recognition", { p_instructor_id: ctx.instructor_id }),
    supabase.rpc("instructor_reliability", { p_instructor_id: ctx.instructor_id }),
    supabase.rpc("calendar_feed_state", { p_studio_id: ctx.studio_id, p_kind: "instructor" }),
  ]);
  const feedState = (feed ?? {}) as { active?: boolean; last_used_at?: string | null };
  const r = data as Rec | null;
  const rel = relData as unknown as
    { applied: number; approved: number; withdrawn: number; short_notice: number } | null;

  return (
    <InstructorShell ctx={ctx} title="Me">
      <div className="m-card px-4 py-4">
        <p className="m-sub text-ink-3">Classes taught here</p>
        <p className="m-stat mt-1 text-ink">{r?.classes_taught ?? 0}</p>
        <p className="m-sub mt-1 text-ink-2">
          <span className="num">{r?.this_month ?? 0}</span> this month
          {(r?.week_streak ?? 0) > 1 && (
            <> · <span className="num">{r!.week_streak}</span> weeks running</>
          )}
        </p>
        {r?.state === "empty" && <p className="m-sub mt-2 text-ink-3">{r.empty_hint}</p>}
      </div>
      <p className="m-sub mt-2 text-ink-3">{r?.not_a_leaderboard}</p>

      {/* Your own shift record — applied, approved, withdrawn. Yours to see, so
          you can manage it yourself before anybody has to mention it. Not a
          score and nothing is held against it. */}
      {rel && rel.applied > 0 && (
        <div className="m-card mt-4 px-4 py-4">
          <p className="m-sub text-ink-3">Open shifts you have taken on</p>
          <p className="mt-1 text-[15px] leading-6 text-ink">
            Applied for <span className="num font-semibold">{rel.applied}</span>,
            approved for <span className="num font-semibold">{rel.approved}</span>,
            withdrew from <span className="num font-semibold">{rel.withdrawn}</span>.
          </p>
          {rel.short_notice > 0 && (
            <p className="m-sub mt-1 text-ink-2">
              <span className="num">{rel.short_notice}</span> of those withdrawals came at short
              notice — inside the studio&rsquo;s cover window, when it is hardest to fill.
            </p>
          )}
          <p className="m-sub mt-1.5 text-ink-3">
            Nobody is scored on this. It is here so you can keep an eye on it yourself.
          </p>
        </div>
      )}

      <p className="m-sub mb-2 mt-6 text-ink-3">Your calendar</p>
      <CalendarFeedControl
        active={feedState.active ?? false}
        lastUsed={feedState.last_used_at ?? null}
        what="your classes"
        actions={{
          mint:   async () => { "use server"; return mintFeed(ctx.studio_id, "instructor"); },
          revoke: async () => { "use server"; return revokeFeed(ctx.studio_id, "instructor"); },
        }}
      />

      <div className="m-card mt-4 px-4 py-4">
        <p className="m-sub text-ink-3">Signed in as</p>
        <p className="mt-0.5 text-[15px] leading-5 text-ink">{ctx.email}</p>
        <p className="m-sub mt-0.5 text-ink-3">{ctx.display_name} · {ctx.studio_name}</p>
        <SignOut to="/instructor/login"
                 className="m-tap mt-3 inline-flex items-center rounded-full px-4 text-[13px] font-bold"
                 style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
          Sign out
        </SignOut>
      </div>

      {/* Availability is monthly, so it lives here rather than earning a tab. */}
      <Link href="/instructor/availability" className="m-card mt-4 flex items-center gap-3 px-4 py-4">
        <span className="flex-1">
          <span className="block text-[15px] leading-5 text-ink">My availability</span>
          <span className="m-sub mt-0.5 block text-ink-3">
            The hours you have given the studio, and the months you have sent.
          </span>
        </span>
        <span className="shrink-0 text-ink-3">›</span>
      </Link>

      <p className="m-sub mt-5 text-ink-3">
        Add this to your home screen and it opens like an app. There is nothing
        to download.{" "}
        <Link href="/instructor" className="underline underline-offset-4">Back to home</Link>
      </p>
    </InstructorShell>
  );
}
