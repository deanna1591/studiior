import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { dayMonthParts, fmtTime } from "@/lib/time";

export const dynamic = "force-dynamic";

/**
 * What they have actually done.
 *
 * This screen is the reason migration 025 exists: occ_member_read is
 * `status = 'scheduled'`, so once a class runs it leaves the member's view and
 * every one of these rows read "Visit" with no name, no time and no teacher.
 * The narrow policy — readable if you have a booking or a check-in for it —
 * is what puts the class names back.
 */
export default async function History() {
  const { ctx, supabase, studioName, logoUrl } = await memberScreen();

  const [{ data: visits }, { data: achievements }] = await Promise.all([
    supabase
      .from("check_ins")
      .select("id, checked_in_at, occurrence_id, import_id, class_occurrences(name, starts_at, instructors!instructor_id(display_name))")
      .eq("member_id", ctx.memberId)
      .order("checked_in_at", { ascending: false })
      .limit(200),
    supabase
      .from("member_achievements")
      .select("id, earned_at, achievement_definitions(name, description, icon)")
      .eq("member_id", ctx.memberId)
      .order("earned_at", { ascending: false }),
  ]);

  const groups: { label: string; items: NonNullable<typeof visits> }[] = [];
  for (const v of visits ?? []) {
    const label = new Intl.DateTimeFormat("en-GB", {
      timeZone: ctx.timeZone, month: "long", year: "numeric",
    }).format(new Date(v.checked_in_at));
    const last = groups[groups.length - 1];
    if (last && last.label === label) last.items.push(v);
    else groups.push({ label, items: [v] });
  }

  return (
    <MemberShell studioName={studioName} logoUrl={logoUrl} title="Your history">
      <div className="mb-5 grid grid-cols-2 gap-3">
        <div className="rounded-lg border border-line bg-surface p-3">
          <p className="m-micro text-ink-3">Classes</p>
          <p className="num text-[26px] leading-8 text-ink">{ctx.lifetimeVisits}</p>
        </div>
        <div className="rounded-lg border border-line bg-surface p-3">
          <p className="m-micro text-ink-3">Weekly streak</p>
          <p className="num text-[26px] leading-8 text-ink">{ctx.streak}</p>
          {/* Decision 5: weeks, not days. Daily streaks punish rest days, which
              is the opposite of what a Pilates studio wants to encourage. */}
          <p className="m-micro text-ink-3">weeks in a row with a class</p>
        </div>
      </div>

      {(achievements ?? []).length > 0 && (
        <section className="mb-6">
          <h2 className="m-sub mb-2 font-medium text-ink">Earned</h2>
          <ul className="flex flex-wrap gap-2">
            {(achievements ?? []).map((a) => {
              const { day, month } = dayMonthParts(a.earned_at, ctx.timeZone);
              return (
                <li key={a.id}
                    className="rounded-full border border-lime-text bg-lime-tint px-3 py-1.5">
                  <span className="m-sub text-ink">
                    {a.achievement_definitions?.name ?? "Achievement"}
                  </span>
                  <span className="m-micro ml-1.5 text-ink-2">
                    <span className="num">{day}</span> {month}
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {(visits ?? []).length === 0 ? (
        <div className="rounded-xl border border-dashed border-line-2 p-5 text-center">
          <p className="m-body text-ink">No classes yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Your first one will show up here.{" "}
            <Link href="/book" className="text-lime-text underline underline-offset-4">
              Find one to book
            </Link>
            .
          </p>
        </div>
      ) : (
        <div className="space-y-5">
          {groups.map((g) => (
            <section key={g.label}>
              <h2 className="m-micro mb-1.5 uppercase tracking-[0.06em] text-ink-3">{g.label}</h2>
              <ul className="divide-y divide-line rounded-xl border border-line bg-surface">
                {g.items.map((v) => {
                  const { day, month } = dayMonthParts(v.checked_in_at, ctx.timeZone);
                  return (
                    <li key={v.id} className="flex items-center justify-between gap-3 px-3 py-2.5">
                      <span className="min-w-0">
                        <span className="m-body block truncate text-ink">
                          {v.class_occurrences?.name ?? "Class"}
                        </span>
                        <span className="m-micro block text-ink-3">
                          {v.class_occurrences?.instructors?.display_name ??
                            (v.import_id ? "From before you joined the app" : "—")}
                        </span>
                      </span>
                      <span className="m-micro shrink-0 text-right text-ink-3">
                        <span className="num">{day}</span> {month}
                        {v.occurrence_id && (
                          <span className="num block">{fmtTime(v.checked_in_at, ctx.timeZone)}</span>
                        )}
                      </span>
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
        </div>
      )}
    </MemberShell>
  );
}
