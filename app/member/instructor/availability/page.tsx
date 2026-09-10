import Link from "next/link";
import { instructorScreen, studioToday } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";

export const dynamic = "force-dynamic";

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/**
 * WHEN I'M FREE — Decision 18, folded in from /my/availability.
 *
 * THEIRS TO STATE AND THE STUDIO'S TO APPROVE. A submitted month narrows
 * nothing until somebody approves it — including the "has this person stated
 * anything at all" test, which is the subtle half: an unapproved submission
 * would otherwise flip an instructor from "stated nothing, so available" to
 * "stated something, and this class is outside it" before anyone said yes.
 *
 * The editor itself stays at /my/availability in the staff app for now, and
 * this screen says so rather than drawing a second one that could disagree
 * with it. A week is replaced as ONE payload — a half-applied week silently
 * changes who the scheduler thinks can teach — and that form is a real piece
 * of work to rebuild phone-first.
 */
export default async function AvailabilityPage() {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);

  const [{ data: week }, { data: subs }] = await Promise.all([
    supabase.rpc("instructor_availability_week", { p_instructor_id: ctx.instructor_id }),
    supabase.from("availability_submissions")
      .select("period_start, status, submitted_at, reviewed_at, note")
      .eq("instructor_id", ctx.instructor_id)
      .order("period_start", { ascending: false }).limit(3),
  ]);

  const rows = (week ?? []) as {
    day_of_week: number; starts_at_time: string | null; ends_at_time: string | null;
    is_available: boolean;
  }[];
  const byDay = new Map<number, typeof rows>();
  for (const r of rows) {
    if (!byDay.has(r.day_of_week)) byDay.set(r.day_of_week, []);
    byDay.get(r.day_of_week)!.push(r);
  }
  const month = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", month: "long", year: "numeric" })
      .format(new Date(`${iso}T00:00:00Z`));

  return (
    <InstructorShell ctx={ctx} title="When I'm free">
      {rows.length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">You have not said yet.</p>
          <p className="m-sub mt-1 text-ink-2">
            Until you do, the studio treats you as available — so nothing is
            blocked, but nothing is protected either.
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {[0, 1, 2, 3, 4, 5, 6].map((d) => {
            const list = byDay.get(d) ?? [];
            return (
              <li key={d} className="m-card flex items-baseline gap-3 px-3 py-2.5">
                <span className="w-[92px] shrink-0 text-[15px] leading-5 text-ink">{DAYS[d]}</span>
                <span className="m-sub flex-1 text-ink-2">
                  {list.length === 0
                    ? <span className="text-ink-3">Not available</span>
                    : list.map((r, i) => (
                        <span key={i} className="num">
                          {i > 0 && ", "}
                          {(r.starts_at_time ?? "").slice(0, 5)}–{(r.ends_at_time ?? "").slice(0, 5)}
                        </span>
                      ))}
                </span>
              </li>
            );
          })}
        </ul>
      )}

      {(subs ?? []).length > 0 && (
        <section className="mt-5">
          <h2 className="m-sub mb-2 text-ink-3">Months you have sent</h2>
          <ul className="space-y-2">
            {(subs ?? []).map((s) => (
              <li key={s.period_start} className="m-card px-3 py-2.5">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-[15px] leading-5 text-ink">{month(s.period_start)}</span>
                  <span className="m-sub text-ink-2">
                    {s.status === "approved" ? "Approved"
                      : s.status === "submitted" ? "With the studio"
                      : s.status === "changes_requested" ? "They have asked for changes"
                      : "Draft"}
                  </span>
                </div>
                {/* "Changes requested" with no note is a refusal wearing a
                    softer word, so the reason is always shown. */}
                {s.status === "changes_requested" && s.note && (
                  <p className="mt-1.5 text-[13px] leading-[19px] text-ink">{s.note}</p>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="m-card mt-5 px-4 py-4">
        <p className="text-[15px] leading-6 text-ink">Changing it</p>
        <p className="m-sub mt-1 text-ink-2">
          The editor is on the full site for now — a week is saved in one go, and
          that form has not been rebuilt for a phone yet.
        </p>
        <Link href="/my/availability"
              className="m-sub mt-2 inline-block underline underline-offset-4"
              style={{ color: "var(--accent-text)" }}>
          Open the editor
        </Link>
        <p className="m-sub mt-2 text-ink-3">
          What you send is a proposal. It changes nothing until the studio
          approves it, and your standing pattern keeps working in the meantime.
        </p>
      </div>
    </InstructorShell>
  );
}
