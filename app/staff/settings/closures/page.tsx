import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink, SectionLabel } from "@/components/ui";
import { studioToday } from "@/lib/tz";
import CloseForm, { ReopenButton } from "./form";

export const dynamic = "force-dynamic";

/**
 * Days the studio is shut.
 *
 * The same idea as an instructor's dated exception, one level up — and with the
 * same asymmetry the archive work found: closing has consequences and is a
 * two-step, reopening has none and is one press.
 */
export default async function Closures() {
  const screen = await staffScreen("/settings/closures");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return (
      <AppShell {...shell} title="Closures">
        <Denied what="Closing the studio" role={ctx.role} />
      </AppShell>
    );
  }

  const today = studioToday(ctx.timeZone);
  const { data: closures } = await supabase
    .from("studio_closures")
    .select("id, starts_on, ends_on, starts_at_time, ends_at_time, reason")
    .order("starts_on", { ascending: false });

  const rows = closures ?? [];
  const upcoming = rows.filter((c) => c.ends_on >= today);
  const past = rows.filter((c) => c.ends_on < today);

  const fmt = (d: string) =>
    new Intl.DateTimeFormat("en-GB", {
      day: "numeric", month: "long", year: "numeric", timeZone: ctx.timeZone,
    }).format(new Date(`${d}T12:00:00Z`));
  const span = (c: (typeof rows)[number]) =>
    (c.starts_on === c.ends_on ? fmt(c.starts_on) : `${fmt(c.starts_on)} – ${fmt(c.ends_on)}`)
    + (c.starts_at_time ? `, ${c.starts_at_time.slice(0, 5)}–${c.ends_at_time?.slice(0, 5)}` : "");

  return (
    <AppShell {...shell} title="Closures"
              actions={<NavLink href="/settings">Back to settings</NavLink>}>
      <p className="mb-6 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        Days you are shut. Nothing is generated for them, anything already on the
        calendar is cancelled properly — members told, credits back, no late fees —
        and the member app says you are closed rather than showing an empty day.
      </p>

      <section className="mb-10">
        <SectionLabel>Close a date</SectionLabel>
        <div className="mt-3"><CloseForm today={today} /></div>
      </section>

      {upcoming.length > 0 && (
        <section className="mb-10">
          <SectionLabel>Coming up — {upcoming.length}</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {upcoming.map((c) => (
              <li key={c.id}
                  className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-3.5 py-3">
                <div className="min-w-0">
                  <div className="text-[14px] leading-5 text-ink">{c.reason}</div>
                  <div className="num text-[12px] leading-4 text-ink-3">{span(c)}</div>
                </div>
                <ReopenButton closureId={c.id} />
              </li>
            ))}
          </ul>
          <p className="mt-2 max-w-[62ch] text-[12.5px] leading-[18px] text-ink-3">
            Reopening is not an undo. Classes that were cancelled stay cancelled —
            those members were told they were off, and a studio changing its mind
            cannot untell them. What comes back is the classes that were never made.
          </p>
        </section>
      )}

      {past.length > 0 && (
        <section>
          <SectionLabel>Past — {past.length}</SectionLabel>
          <ul className="mt-2 divide-y divide-line rounded-xl border border-line bg-surface">
            {past.map((c) => (
              <li key={c.id} className="px-3.5 py-2.5">
                <span className="text-[14px] leading-5 text-ink-2">{c.reason}</span>
                <span className="num ml-2 text-[12px] leading-4 text-ink-3">{span(c)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </AppShell>
  );
}
