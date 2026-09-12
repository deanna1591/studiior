import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { SignOut } from "@/components/member/sign-out";

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
  const { data } = await supabase.rpc("instructor_recognition", {
    p_instructor_id: ctx.instructor_id,
  });
  const r = data as Rec | null;

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

      {/* Said rather than half-drawn. Three things an instructor might look for
          are not here, and each is a rule rather than an omission. */}
      <div className="m-card mt-4 px-4 py-4">
        <p className="text-[15px] leading-6 text-ink">What is not here</p>
        <ul className="m-sub mt-2 space-y-2 text-ink-2">
          <li>
            <span className="text-ink">Messaging members.</span> Staff write to
            members, never instructors — §12. If somebody needs telling
            something, tell the studio.
          </li>
          <li>
            <span className="text-ink">Contact details.</span> §14 keeps a
            member&rsquo;s email and phone with the office, including on your
            rosters.
          </li>
          <li>
            <span className="text-ink">Member progress and history.</span> You
            see what you need to teach the class well — who is coming, whether
            they are new, and anything the studio has pinned.
          </li>
        </ul>
      </div>

      <p className="m-sub mt-5 text-ink-3">
        Add this to your home screen and it opens like an app. There is nothing
        to download.{" "}
        <Link href="/instructor" className="underline underline-offset-4">Back to my week</Link>
      </p>
    </InstructorShell>
  );
}
