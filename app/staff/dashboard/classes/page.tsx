import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { studioToday } from "@/lib/dashboard";
import { fmtTime } from "@/lib/time";
import { AppShell, Denied, Empty } from "@/components/ui";

export const dynamic = "force-dynamic";

/**
 * Decision 86. Today's classes, the list behind both the bookings card (every
 * class with its seats) and the attendance card (?ended=1, the classes that
 * have finished, with who came). One screen, two readings, so the card and the
 * page can never count a different set. Desk-up.
 */

type Seat = {
  booking_id: string;
  member_id: string;
  name: string;
  seat_kind: "free_first" | "complimentary" | "drop_in_paid" | "drop_in_unpaid" | "plan";
  checked_in: boolean;
  state: "attended" | "no_show" | "pending" | "booked";
};
type Klass = {
  occurrence_id: string;
  name: string;
  starts_at: string;
  ends_at: string;
  room: string | null;
  instructor: string | null;
  capacity: number;
  booked: number;
  status: string;
  ended: boolean;
  members: Seat[];
};

const SEAT_LABEL: Record<Seat["seat_kind"], string> = {
  free_first: "Free first class",
  complimentary: "Complimentary",
  drop_in_paid: "Drop-in, paid",
  drop_in_unpaid: "Drop-in, unpaid",
  plan: "Plan",
};

export default async function ClassesTodayPage({
  searchParams,
}: {
  searchParams: { ended?: string };
}) {
  const screen = await staffScreen("/dashboard/classes");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Today's classes"><Denied what="the schedule" role={ctx.role} /></AppShell>;
  }

  const endedOnly = searchParams.ended === "1";
  const today = studioToday(ctx.timeZone);
  const { data, error } = await supabase.rpc("dashboard_today_classes", {
    p_studio_id: ctx.studioId,
    p_date: today,
  });
  const all = (data ?? []) as Klass[];
  const classes = endedOnly ? all.filter((c) => c.ended) : all;

  const title = endedOnly ? "Attendance today" : "Today's classes";

  return (
    <AppShell
      {...shell}
      title={title}
      actions={
        <>
          <Link
            href={endedOnly ? "/dashboard/classes" : "/dashboard/classes?ended=1"}
            className="text-[13px] leading-[18px] text-lime-text underline underline-offset-4 hover:text-lime-text2"
          >
            {endedOnly ? "All of today's classes" : "Only the ones that have finished"}
          </Link>
          <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
            Back to the dashboard
          </Link>
        </>
      }
    >
      {error ? (
        <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            Today&rsquo;s classes could not be read. This is not an empty day.
          </p>
          <p className="num mt-1.5 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      ) : classes.length === 0 ? (
        <Empty>
          {endedOnly ? "No classes have finished yet today." : "Nothing is on today."}
        </Empty>
      ) : (
        <div className="space-y-3">
          {classes.map((c) => {
            const came = c.members.filter((m) => m.checked_in).length;
            return (
              <div key={c.occurrence_id} className="panel p-4">
                <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                  <span className="flex items-baseline gap-2.5">
                    <Link
                      href={`/roster/${c.occurrence_id}`}
                      className="text-[15px] font-semibold leading-5 text-ink hover:underline underline-offset-2"
                    >
                      {c.name}
                    </Link>
                    <span className="text-[12px] leading-4 text-ink-3">
                      <span className="num">{fmtTime(c.starts_at, ctx.timeZone, ctx.timeFormat)}</span>
                      {c.room && <>{" · "}{c.room}</>}
                      {c.instructor && <>{" · "}{c.instructor}</>}
                    </span>
                  </span>
                  <span className="num text-[12px] leading-4 text-ink-2">
                    {c.ended ? <>{came} of {c.members.length} came in</> : <>{c.booked}/{c.capacity} booked</>}
                  </span>
                </div>
                {c.members.length === 0 ? (
                  <p className="text-[12px] leading-4 text-ink-3">Nobody is booked.</p>
                ) : (
                  <ul className="divide-y divide-line">
                    {c.members.map((m) => (
                      <li key={m.booking_id} className="flex items-baseline justify-between gap-x-4 py-1.5">
                        <Link href={`/members/${m.member_id}`} className="text-[13px] leading-5 text-ink hover:underline underline-offset-2">
                          {m.name}
                        </Link>
                        <span className="flex items-baseline gap-2 text-[11px] leading-4 text-ink-3">
                          <span>{SEAT_LABEL[m.seat_kind]}</span>
                          {/* "Checked in" is live for a today class before it ends;
                              "Did not attend" / "Not marked" are only for ended classes. */}
                          {(m.checked_in || c.ended) && (
                            <span className={m.checked_in ? "text-lime-text" : m.state === "no_show" ? "text-coral-deep" : "text-ink-3"}>
                              {m.checked_in ? "Checked in" : m.state === "no_show" ? "Did not attend" : "Not marked"}
                            </span>
                          )}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            );
          })}
        </div>
      )}
    </AppShell>
  );
}
