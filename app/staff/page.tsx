import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty, Pill, PillRow, Rows, Segmented, SectionLabel } from "@/components/ui";
import { ScheduleRow, type Occ } from "@/components/schedule-rows";
import {
  addDays, dayStart, fmtDayLong, relativeDayName, weekStart, zonedDateKey,
} from "@/lib/time";

export const dynamic = "force-dynamic";

export default async function Schedule({
  searchParams,
}: {
  searchParams: { view?: string; d?: string; room?: string; instructor?: string };
}) {
  const screen = await staffScreen("/");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Day is the default. A week is roughly ninety rows, which is a scroll, not
  // a glance — the week is there when you want to plan, and the day is what
  // you have open at the desk.
  const view = searchParams.view === "week" ? "week" : "day";
  const offset = Number(searchParams.d ?? 0) || 0;

  const from = view === "week"
    ? weekStart(new Date(), ctx.timeZone, offset)
    : dayStart(new Date(), ctx.timeZone, offset);
  const to = addDays(from, view === "week" ? 7 : 1);

  const [{ data: occurrences }, { data: rooms }] =
    await Promise.all([
      supabase
        .from("class_occurrences")
        .select("id, name, starts_at, capacity, booked_count, waitlist_count, status, room_id, instructor_id, instructors!instructor_id(display_name), rooms(name)")
        .gte("starts_at", from.toISOString())
        .lt("starts_at", to.toISOString())
        .order("starts_at"),
      supabase.from("rooms").select("id, name").eq("status", "active").order("name"),
    ]);

  const roomFilter = searchParams.room ?? "";
  const shown = (occurrences ?? []).filter((o) => !roomFilter || o.room_id === roomFilter);

  const qs = (over: Record<string, string | number | undefined>) => {
    const p = new URLSearchParams();
    const merged = { view, d: offset, room: roomFilter || undefined, ...over };
    for (const [k, v] of Object.entries(merged)) {
      if (v !== undefined && v !== "" && !(k === "d" && v === 0) && !(k === "view" && v === "day")) {
        p.set(k, String(v));
      }
    }
    const s = p.toString();
    return s ? `/?${s}` : "/";
  };

  // Grouped by day either way, so the week is the same rows under headings
  // rather than a different component.
  const byDay = new Map<string, Occ[]>();
  for (const o of shown) {
    const key = zonedDateKey(o.starts_at, ctx.timeZone);
    if (!byDay.has(key)) byDay.set(key, []);
    byDay.get(key)!.push(o as Occ);
  }
  const days = Array.from({ length: view === "week" ? 7 : 1 }, (_, i) => addDays(from, i));
  const now = Date.now();

  const heading = (() => {
    const iso = from.toISOString();
    if (view === "week") return "Schedule";
    return relativeDayName(iso, ctx.timeZone) ?? fmtDayLong(iso, ctx.timeZone);
  })();

  return (
    <AppShell
      {...shell}
      title={heading}
      actions={
        isManagerUp(ctx.role) ? (
          <Link
            href="/classes/new"
            className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2"
          >
            Add a class
          </Link>
        ) : null
      }
      filters={
        <PillRow
          right={
            <div className="flex items-center gap-2">
              <Link href={qs({ d: offset - 1 })} aria-label="Previous"
                    className="num flex h-7 w-7 items-center justify-center rounded-full border border-line-2 bg-surface text-ink-2 hover:text-ink">‹</Link>
              <Link href={qs({ d: 0 })}
                    className="text-[12px] text-ink-3 underline underline-offset-4 hover:text-ink">
                {view === "week" ? "This week" : "Today"}
              </Link>
              <Link href={qs({ d: offset + 1 })} aria-label="Next"
                    className="num flex h-7 w-7 items-center justify-center rounded-full border border-line-2 bg-surface text-ink-2 hover:text-ink">›</Link>
              <Segmented
                options={[
                  { href: qs({ view: "day", d: 0 }), label: "Day", active: view === "day" },
                  { href: qs({ view: "week", d: 0 }), label: "Week", active: view === "week" },
                ]}
              />
            </div>
          }
        >
          <Pill href={qs({ room: undefined })} active={!roomFilter}>All rooms</Pill>
          {(rooms ?? []).map((r) => (
            <Pill key={r.id} href={qs({ room: r.id })} active={roomFilter === r.id}>
              {r.name}
            </Pill>
          ))}
        </PillRow>
      }
    >
      {shown.length === 0 ? (
        <Empty>
          {roomFilter
            ? <>Nothing in that room {view === "week" ? "this week" : "on this day"}. <Link href={qs({ room: undefined })} className="text-lime-text underline underline-offset-4">Show every room</Link>.</>
            : isManagerUp(ctx.role)
              ? <>No classes {view === "week" ? "this week" : "today"}. <Link href="/classes/new" className="text-lime-text underline underline-offset-4">Add one</Link> and members can book it.</>
              : <>No classes {view === "week" ? "this week" : "today"}.</>}
        </Empty>
      ) : view === "day" ? (
        <Rows>
          {shown.map((o) => (
            <ScheduleRow key={o.id} o={o as Occ} timeZone={ctx.timeZone} now={now} />
          ))}
        </Rows>
      ) : (
        <div className="space-y-6">
          {days.map((d) => {
            const key = zonedDateKey(d.toISOString(), ctx.timeZone);
            const list = byDay.get(key) ?? [];
            return (
              <section key={key}>
                <SectionLabel>
                  {relativeDayName(d.toISOString(), ctx.timeZone) ?? fmtDayLong(d.toISOString(), ctx.timeZone)}
                </SectionLabel>
                {list.length === 0 ? (
                  <p className="border-y border-line bg-surface px-3 py-2.5 text-[13px] text-ink-3">
                    Nothing on.
                  </p>
                ) : (
                  <Rows>
                    {list.map((o) => (
                      <ScheduleRow key={o.id} o={o} timeZone={ctx.timeZone} now={now} />
                    ))}
                  </Rows>
                )}
              </section>
            );
          })}
        </div>
      )}
    </AppShell>
  );
}
