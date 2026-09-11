import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Notice, SectionLabel } from "@/components/ui";
import PublishForm from "./publish-form";
import { confirmRosterFor } from "./actions";
import { buttonQuietClass } from "@/components/ui";

export const dynamic = "force-dynamic";

type Facts = {
  month: string; label: string; enabled: boolean;
  is_current: boolean; is_past: boolean;
  published: boolean; published_at: string | null; auto: boolean;
  classes: number; open_shifts: number; bookings: number;
  instructors: {
    instructor_id: string; name: string; classes: number; reachable: boolean;
    notified_at: string | null; confirmed_at: string | null; cover_pending: number;
  }[];
};

/** What one instructor's row says about the roster, once the month is out. */
function rosterState(i: Facts["instructors"][number]) {
  if (i.confirmed_at) {
    return i.cover_pending > 0
      ? `confirmed · ${i.cover_pending} flagged for cover`
      : "confirmed";
  }
  if (i.cover_pending > 0) return `${i.cover_pending} flagged for cover · not confirmed`;
  if (i.notified_at) return "sent · not confirmed";
  if (!i.reachable) return "not sent";
  return "not sent";
}

/**
 * Decision 25: the month is the unit, so the screen is a list of months.
 *
 * This month and the next three, each read through publish_month_preview() —
 * the same facts publish_month() records, so what a manager read before
 * pressing is what the row says afterwards. Everything the brief says a studio
 * must see before publishing is in the selected month's card: how many
 * classes, how many still unstaffed, which instructors and how many each.
 *
 * Publishing with holes is allowed and warned, never blocked. An open shift is
 * a real state and Decision 17 handles it.
 */
export default async function PublishPage({ searchParams }: { searchParams: { m?: string; just?: string; err?: string } }) {
  const screen = await staffScreen("/publish");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Publish">
        <Denied what="Publishing the timetable" role={ctx.role} />
      </AppShell>
    );
  }

  if (!ctx.publicationEnabled) {
    return (
      <AppShell {...shell} title="Publish">
        <p className="max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
          Your timetable is live as soon as it is made — every month is visible and bookable
          the moment its classes exist. If you would rather build a month as a draft and
          publish it when it is ready, turn that on under{" "}
          <Link href="/settings" className="underline underline-offset-4">Settings</Link>.
        </p>
      </AppShell>
    );
  }

  // The studio's months, from its own clock. The first of this month in the
  // studio's zone, as a date key, then +1..+3 months by wall arithmetic.
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: ctx.timeZone, year: "numeric", month: "numeric",
  }).formatToParts(new Date());
  const y = Number(parts.find((p) => p.type === "year")?.value);
  const m0 = Number(parts.find((p) => p.type === "month")?.value);
  const monthKey = (offset: number) => {
    const d = new Date(Date.UTC(y, m0 - 1 + offset, 1));
    return d.toISOString().slice(0, 10);
  };
  const months = [0, 1, 2, 3].map(monthKey);

  const previews = await Promise.all(
    months.map((mk) => supabase.rpc("publish_month_preview", { p_studio_id: ctx.studioId, p_month: mk })),
  );
  const facts = previews.map((p) => p.data as unknown as Facts | null);
  const failed = previews.find((p) => p.error)?.error ?? null;

  // The selected month: ?m=YYYY-MM, else the first draft, else this month.
  const wanted = searchParams.m ? `${searchParams.m}-01` : null;
  const selected =
    facts.find((f) => f && f.month === wanted) ??
    facts.find((f) => f && !f.published) ??
    facts[0];

  const when = (iso: string) =>
    new Intl.DateTimeFormat("en-GB", {
      day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
      timeZone: ctx.timeZone,
    }).format(new Date(iso));

  return (
    <AppShell {...shell} title="Publish">
      <p className="mb-6 max-w-[64ch] text-[13px] leading-[19px] text-ink-2">
        A month is a draft until you publish it. Members see and book only published months;
        instructors are sent their own classes to confirm when you publish. Fill the month
        first, then publish it here.
      </p>

      {failed && (
        <div className="mb-4 max-w-[60ch] border-l-[3px] bg-coral-tint px-3 py-2 text-[13px] leading-[19px] text-ink"
             style={{ borderLeftColor: "var(--coral)" }} role="alert">
          The months could not be read — this is not an empty timetable.
          <span className="num block text-[12px] text-ink-2">{failed.message}</span>
        </div>
      )}

      {searchParams.err && <Notice kind="error">{searchParams.err}</Notice>}

      {/* Rendered from the facts, not from a message the action carried back:
          the row says who was sent a roster and who could not be. */}
      {searchParams.just === "1" && selected?.published && (
        <Notice kind="ok">
          {selected.label} is published: {selected.classes} classes,{" "}
          {selected.instructors.filter((i) => i.notified_at).length} sent their roster.
          {selected.open_shifts > 0 && (
            <> {selected.open_shifts} {selected.open_shifts === 1 ? "class has" : "classes have"} nobody
            teaching yet — {selected.open_shifts === 1 ? "it is an open shift" : "they are open shifts"} now.</>
          )}
          {selected.instructors.some((i) => !i.reachable) && (
            <span className="block">
              No login, so nothing was emailed — tell them yourself:{" "}
              {selected.instructors.filter((i) => !i.reachable).map((i) => `${i.name} (${i.classes})`).join(", ")}.
            </span>
          )}
        </Notice>
      )}

      <div className="grid gap-8 md:grid-cols-[minmax(0,18rem)_minmax(0,1fr)]">
        <section>
          <SectionLabel>Months</SectionLabel>
          <ul className="mt-3 divide-y divide-line rounded border border-line bg-surface">
            {facts.map((f) => f && (
              <li key={f.month}>
                <Link href={`/publish?m=${f.month.slice(0, 7)}`}
                      className={`block px-3.5 py-3 hover:bg-paper ${selected?.month === f.month ? "bg-paper" : ""}`}
                      aria-current={selected?.month === f.month ? "page" : undefined}>
                  <span className="flex items-baseline justify-between gap-3">
                    <span className="text-[13px] font-medium leading-[18px] text-ink">{f.label}</span>
                    <span className="text-[12px] leading-4 text-ink-2">
                      {f.published ? "Published" : f.classes === 0 ? "Nothing yet" : "Draft"}
                    </span>
                  </span>
                  <span className="num mt-0.5 block text-[12px] leading-4 text-ink-3">
                    {f.classes} {f.classes === 1 ? "class" : "classes"}
                    {f.open_shifts > 0 && ` · ${f.open_shifts} unstaffed`}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        </section>

        {selected && (
          <section>
            <SectionLabel>{selected.label}</SectionLabel>

            <div className="mt-3 grid grid-cols-3 gap-x-6 gap-y-4">
              <div>
                <div className="num text-[20px] leading-7 text-ink">{selected.classes}</div>
                <div className="text-[12px] leading-4 text-ink-2">classes</div>
              </div>
              <div>
                <div className="num text-[20px] leading-7 text-ink">{selected.open_shifts}</div>
                <div className="text-[12px] leading-4 text-ink-2">with nobody teaching</div>
              </div>
              <div>
                <div className="num text-[20px] leading-7 text-ink">{selected.instructors.length}</div>
                <div className="text-[12px] leading-4 text-ink-2">instructors affected</div>
              </div>
            </div>

            {selected.published && selected.instructors.length > 0 && (
              <p className="mt-5 text-[13px] leading-[19px] text-ink-2">
                <span className="num">{selected.instructors.filter((i) => i.confirmed_at).length}</span> of{" "}
                <span className="num">{selected.instructors.length}</span> have confirmed the month.
                {selected.instructors.some((i) => !i.confirmed_at && !i.reachable) && (
                  <> Somebody with no login cannot confirm from the app — you can confirm for them once they have said yes.</>
                )}
              </p>
            )}

            {selected.instructors.length > 0 && (
              <ul className={`${selected.published ? "mt-2" : "mt-5"} divide-y divide-line rounded border border-line bg-surface`}>
                {selected.instructors.map((i) => (
                  <li key={i.instructor_id} className="flex items-baseline justify-between gap-3 px-3.5 py-2.5">
                    <span className="text-[13px] leading-[18px] text-ink">
                      <Link href={`/instructors/${i.instructor_id}`} className="hover:underline">{i.name}</Link>
                      {!i.reachable && (
                        <span className="block text-[12px] leading-4 text-ink-3">no login — cannot be emailed</span>
                      )}
                    </span>
                    <span className="flex shrink-0 items-center gap-3">
                      <span className="num text-right text-[12px] leading-4 text-ink-2">
                        {i.classes} {i.classes === 1 ? "class" : "classes"}
                        {selected.published && (
                          <span className="block text-ink-3">{rosterState(i)}</span>
                        )}
                      </span>
                      {selected.published && !i.confirmed_at && (
                        <form action={confirmRosterFor}>
                          <input type="hidden" name="month" value={selected.month} />
                          <input type="hidden" name="instructor_id" value={i.instructor_id} />
                          <button className={buttonQuietClass} title="Record that they have said yes some other way">
                            Confirm for them
                          </button>
                        </form>
                      )}
                    </span>
                  </li>
                ))}
              </ul>
            )}

            {selected.published ? (
              <p className="mt-5 max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
                Published {selected.published_at ? when(selected.published_at) : ""}
                {selected.auto && " automatically when publication was turned on — it had already started, or members had already booked into it, so nobody was sent a roster"}
                . Members can book it. A class you add to it now is bookable straight away and
                its instructor is told on its own.
              </p>
            ) : selected.is_past ? (
              <p className="mt-5 text-[13px] leading-[19px] text-ink-2">
                This month has ended and is on the record whatever anybody presses.
              </p>
            ) : selected.classes === 0 ? (
              <p className="mt-5 max-w-[60ch] text-[13px] leading-[19px] text-ink-2">
                Nothing on the calendar for {selected.label} yet. Your recurring classes
                fill it as the{" "}
                <Link href="/settings" className="underline underline-offset-4">horizon</Link>{" "}
                reaches it, or add classes on the{" "}
                <Link href="/schedule" className="underline underline-offset-4">schedule</Link>.
              </p>
            ) : (
              <PublishForm
                month={selected.month}
                label={selected.label}
                openShifts={selected.open_shifts}
                unreachable={selected.instructors.filter((i) => !i.reachable).map((i) => i.name)}
              />
            )}

            {!selected.published && selected.is_current && selected.classes > 0 && (
              <p className="mt-3 max-w-[60ch] border-l-[3px] bg-coral-tint px-3 py-2 text-[13px] leading-[19px] text-ink"
                 style={{ borderLeftColor: "var(--coral)" }}>
                <span className="font-medium">This month is not published.</span> Members
                cannot see or book anything in it until it is.
              </p>
            )}
          </section>
        )}
      </div>
    </AppShell>
  );
}
