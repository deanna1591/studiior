import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { AskForCover, CheckIn } from "../../actions-ui";

export const dynamic = "force-dynamic";

type Member = {
  booking_id: string; member_id: string; name: string; avatar_url: string | null;
  booking_status: string; checked_in: boolean; first_timer: boolean; birthday: boolean;
  pinned_notes: { category: string; body: string }[];
};
type Roster = {
  occurrence_id: string; name: string; local_time: string; local_date: string;
  capacity: number; booked: number; status: string;
  members: Member[]; can_check_in: boolean; withheld: string;
};

/**
 * THE ROSTER — the screen that makes an instructor good at their job.
 *
 * Knowing about the shoulder BEFORE the class rather than after. What that
 * takes is a name, a face, whether they have been before, and whatever the
 * studio has pinned.
 *
 * What is NOT here is decided in the database, not in this file:
 * instructor_roster() never returns a contact detail, never returns a document,
 * and never returns a managers-only note. §14 keeps all three with the office,
 * and putting the rule in the reader means no future screen can forget it.
 */
export default async function RosterPage({ params }: { params: { id: string } }) {
  const { ctx, supabase } = await instructorScreen();
  const { data, error } = await supabase.rpc("instructor_roster", {
    p_occurrence_id: params.id,
  });
  const r = data as Roster | null;

  if (error || !r) {
    return (
      <InstructorShell ctx={ctx} title="Class">
        <div className="m-card border-l-[3px] px-3 py-2.5" style={{ borderLeftColor: "var(--coral)" }}>
          <p className="text-[15px] leading-6 text-ink">
            {error?.message?.includes("not your class")
              ? "That is not one of your classes."
              : "This could not be read."}
          </p>
          {error && <p className="num mt-1 text-[11px] leading-4 text-ink-2">{error.message}</p>}
          <Link href="/instructor" className="m-sub mt-2 inline-block text-ink-2 underline underline-offset-4">
            Back to my week
          </Link>
        </div>
      </InstructorShell>
    );
  }

  const day = new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC", weekday: "long", day: "numeric", month: "long",
  }).format(new Date(`${r.local_date}T00:00:00Z`));

  return (
    <InstructorShell ctx={ctx} title={r.name}>
      <p className="m-sub -mt-3 mb-4 text-ink-2">
        {day} at <span className="num">{r.local_time}</span> ·{" "}
        <span className="num">{r.booked}</span>/<span className="num">{r.capacity}</span> booked
      </p>

      {r.members.length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">Nobody booked in yet.</p>
          <p className="m-sub mt-1 text-ink-3">
            Anyone who books appears here, with anything the studio has pinned about them.
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {r.members.map((m) => (
            <li key={m.booking_id} className="m-card px-3 py-3">
              <div className="flex items-center gap-3">
                <span className="flex h-10 w-10 shrink-0 items-center justify-center overflow-hidden rounded-full"
                      style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                  {m.avatar_url
                    /* eslint-disable-next-line @next/next/no-img-element */
                    ? <img src={m.avatar_url} alt="" className="h-full w-full object-cover" />
                    : <span className="text-[15px] font-semibold">{m.name.charAt(0)}</span>}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[15px] leading-5 text-ink">{m.name}</span>
                  <span className="m-sub block text-ink-3">
                    {m.checked_in ? "Here" : m.booking_status === "no_show" ? "Did not come" : "Booked"}
                  </span>
                </span>
                {/* §8 gives an instructor check-in. It does NOT give them
                    "correct a no-show" or "add a walk-in", so those are absent
                    rather than drawn and refused. */}
                {r.can_check_in && !m.checked_in && m.booking_status === "booked" && (
                  <CheckIn studioId={ctx.studio_id} occurrenceId={r.occurrence_id}
                           bookingId={m.booking_id} memberId={m.member_id} />
                )}
              </div>

              {(m.first_timer || m.birthday) && (
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {/* A MEMBER'S FIRST EVER CLASS is the one thing an instructor
                      most needs to know, and the fact that decides how the next
                      hour goes. */}
                  {m.first_timer && (
                    <span className="rounded-full px-2.5 py-1 text-[12px] font-semibold leading-4"
                          style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                      First ever class
                    </span>
                  )}
                  {m.birthday && (
                    <span className="rounded-full px-2.5 py-1 text-[12px] leading-4"
                          style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
                      Birthday today
                    </span>
                  )}
                </div>
              )}

              {m.pinned_notes.length > 0 && (
                <ul className="mt-2 space-y-1.5">
                  {m.pinned_notes.map((n, i) => (
                    <li key={i} className="rounded-lg px-2.5 py-2 text-[13px] leading-[19px] text-ink"
                        style={{
                          background: n.category === "injury" || n.category === "medical"
                            ? "var(--coral-tint)" : "var(--paper)",
                          borderLeft: n.category === "injury" || n.category === "medical"
                            ? "3px solid var(--coral)" : "3px solid var(--line-2)",
                        }}>
                      {n.body}
                    </li>
                  ))}
                </ul>
              )}
            </li>
          ))}
        </ul>
      )}

      {r.status === "scheduled" && <AskForCover occurrenceId={r.occurrence_id} />}

      <p className="m-sub mt-5 text-ink-3">{r.withheld}</p>
    </InstructorShell>
  );
}
