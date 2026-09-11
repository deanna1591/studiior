import Link from "next/link";
import { instructorScreen, studioToday } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { ConfirmMonth, AskForCover } from "../actions-ui";

export const dynamic = "force-dynamic";

type Klass = {
  occurrence_id: string; name: string; local_date: string;
  local_start: string; local_end: string; room_name: string | null;
  capacity: number; booked_count: number; status: string;
  cover_status: string | null; added_after_roster: boolean;
};
type Roster = {
  month: string; label: string; state: "draft" | "empty" | "unconfirmed" | "confirmed";
  classes: Klass[]; count: number; notified_at: string | null; confirmed_at: string | null;
  added_since: number; empty_hint: string;
};

/**
 * MY MONTH — Decision 25's roster, on the phone, with the one thing to do.
 *
 * Reached from the roster email and from the card on My week. The list is
 * their own classes for the month, dates and times; the button confirms the
 * lot; "ask for cover" on a class is the flag, which raises Decision 18's
 * cover request and nothing else. Both confirmations stay: this is the
 * agreement, the week is the check-in.
 *
 * A DRAFT month says it is a draft. It never lists a class the studio has not
 * published — the reader refuses, not the screen.
 */
export default async function MyMonth({ searchParams }: { searchParams: { m?: string } }) {
  const { ctx, supabase } = await instructorScreen();
  const today = studioToday(ctx.timezone);
  // ?m=YYYY-MM, else next month — the one a roster is about.
  const monthKey = /^\d{4}-\d{2}$/.test(searchParams.m ?? "")
    ? `${searchParams.m}-01`
    : (() => { const d = new Date(`${today.slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1); return d.toISOString().slice(0, 10); })();

  const { data, error } = await supabase.rpc("my_month_roster", {
    p_instructor_id: ctx.instructor_id, p_month: monthKey,
  });
  const r = data as unknown as Roster | null;

  const byDay = new Map<string, Klass[]>();
  for (const c of r?.classes ?? []) {
    if (!byDay.has(c.local_date)) byDay.set(c.local_date, []);
    byDay.get(c.local_date)!.push(c);
  }
  const dayLabel = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "UTC", weekday: "long", day: "numeric", month: "short",
    }).format(new Date(`${iso}T00:00:00Z`));
  const shift = (months: number) => {
    const d = new Date(`${monthKey}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + months);
    return d.toISOString().slice(0, 7);
  };
  const flagged = (r?.classes ?? []).filter((c) => c.cover_status).length;

  return (
    <InstructorShell ctx={ctx} title={r?.label ?? "My month"}>
      {error && (
        <div className="m-card mb-4 border-l-[3px] px-3 py-2.5"
             style={{ borderLeftColor: "var(--coral)" }} role="alert">
          <p className="text-[13px] leading-[19px] text-ink">
            Your month could not be read — this is not an empty month.
          </p>
          <p className="num mt-1 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      )}

      {r?.state === "unconfirmed" && (
        <ConfirmMonth instructorId={ctx.instructor_id} month={r.month} label={r.label}
                      count={r.count} flagged={flagged} />
      )}
      {r?.state === "confirmed" && (
        <p className="m-card mb-4 px-4 py-3 text-[13px] leading-[19px] text-ink-2">
          Confirmed. Ask for cover on any class below if something changes — the
          studio decides, and you are down to teach it until they do.
        </p>
      )}
      {r && r.added_since > 0 && (
        <p className="m-card mb-4 px-4 py-3 text-[13px] leading-[19px] text-ink">
          <span className="num font-semibold">{r.added_since}</span>{" "}
          {r.added_since === 1 ? "class was" : "classes were"} added after your roster
          was sent — {r.added_since === 1 ? "it is" : "they are"} marked below.
        </p>
      )}

      {(r?.classes ?? []).length === 0 ? (
        <div className="m-card px-4 py-6">
          <p className="text-[15px] leading-6 text-ink">
            {r?.state === "draft" ? "Not published yet." : "Nothing on."}
          </p>
          <p className="m-sub mt-1 text-ink-2">{r?.empty_hint}</p>
        </div>
      ) : (
        <div className="space-y-5">
          {[...byDay.entries()].map(([day, list]) => (
            <section key={day}>
              <h2 className="m-sub mb-2 text-ink-3">{dayLabel(day)}</h2>
              <ul className="space-y-2">
                {list.map((c) => (
                  <li key={c.occurrence_id} className="m-card px-3 py-2.5">
                    <Link href={`/instructor/roster/${c.occurrence_id}`} className="block">
                      <div className="flex items-baseline gap-3">
                        <span className="num shrink-0 text-[16px] font-semibold leading-5 text-ink">
                          {c.local_start}
                        </span>
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-[15px] leading-5 text-ink">{c.name}</span>
                          <span className="m-sub block text-ink-3">
                            {c.room_name ?? "No room"} · {c.local_start}–{c.local_end}
                            {c.added_after_roster && " · added since your roster"}
                          </span>
                        </span>
                        <span className="num shrink-0 text-[13px] leading-5 text-ink-2">
                          {c.booked_count}/{c.capacity}
                        </span>
                      </div>
                    </Link>
                    {c.cover_status === "pending" && (
                      <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
                        Flagged — you have asked for cover. The studio decides.
                      </p>
                    )}
                    {c.cover_status === "approved" && (
                      <p className="mt-1.5 text-[12px] leading-[17px] text-ink-2">
                        Cover approved — this one is being reassigned.
                      </p>
                    )}
                    {!c.cover_status && <AskForCover occurrenceId={c.occurrence_id} compact />}
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}

      <div className="mt-6 flex items-center justify-between">
        <Link href={`/instructor/month?m=${shift(-1)}`}
              className="m-sub text-ink-2 underline underline-offset-4">← Earlier</Link>
        <Link href="/instructor" className="m-sub text-ink-2 underline underline-offset-4">My week</Link>
        <Link href={`/instructor/month?m=${shift(1)}`}
              className="m-sub text-ink-2 underline underline-offset-4">Later →</Link>
      </div>
    </InstructorShell>
  );
}
