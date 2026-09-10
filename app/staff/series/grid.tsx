import Link from "next/link";
import { DAYS, parseRrule } from "@/lib/rrule";

export type GridSeries = {
  id: string;
  name: string;
  rrule: string;
  time_of_day: string;
  duration_minutes: number;
  ends_on: string | null;
  room_name: string | null;
  class_type_id: string | null;
  class_type_name: string | null;
  class_type_color: string | null;
  /**
   * Ended by STATUS rather than by date. A series stopped because its class type
   * or its room was archived carries no end date at all, so `ends_on < today`
   * cannot see it — and it would otherwise draw as though it were still running.
   */
  ended?: boolean;
};

const MIN_IN_DAY = 24 * 60;
const toMinutes = (t: string) => {
  const [h, m] = t.split(":").map(Number);
  return h * 60 + (m || 0);
};
const hhmm = (mins: number) =>
  `${String(Math.floor(mins / 60)).padStart(2, "0")}:${String(mins % 60).padStart(2, "0")}`;

/**
 * The standing timetable as a week.
 *
 * NOT a second calendar. There are no instructors, no bookings and no dates on
 * it, because it answers "what does our week look like" — `/schedule` answers
 * "what is actually happening", and the moment this grid grows a date it starts
 * disagreeing with that one.
 *
 * The shape is the point: a list cannot show a hole. A studio reading its own
 * list of thirteen rows sees thirteen rows; the same thirteen in a grid make a
 * 10:00–16:00 weekday gap impossible to miss, which is the question a studio is
 * actually asking when it opens this screen.
 */
export default function SeriesGrid({
  series, weekStartsOn, today,
}: {
  series: GridSeries[];
  /** 0 = Sunday. The studio's own setting, not date-fns' idea of a week. */
  weekStartsOn: number;
  today: string;
}) {
  // A series appears in EVERY day its rule names — one series, several cells.
  type Block = GridSeries & { day: number; start: number; end: number; isEnded: boolean };
  const blocks: Block[] = [];
  const unplaceable: GridSeries[] = [];

  for (const s of series) {
    const { rule, unsupported } = parseRrule(s.rrule);
    if (unsupported || rule.days.length === 0) {
      unplaceable.push(s);
      continue;
    }
    const start = toMinutes(s.time_of_day);
    const end = Math.min(MIN_IN_DAY, start + s.duration_minutes);
    const isEnded = (s.ended ?? false) || (s.ends_on !== null && s.ends_on < today);
    for (const code of rule.days) {
      const day = DAYS.findIndex((d) => d.code === code);
      if (day >= 0) blocks.push({ ...s, day, start, end, isEnded });
    }
  }

  // The hours actually used, an hour either side. Cropping to the busy band is
  // what hides the middle of the day, and the middle of the day is the whole
  // reason to draw this.
  const from = blocks.length
    ? Math.max(0, Math.floor(Math.min(...blocks.map((b) => b.start)) / 60) - 1) : 6;
  const to = blocks.length
    ? Math.min(24, Math.ceil(Math.max(...blocks.map((b) => b.end)) / 60) + 1) : 20;
  const hours = Array.from({ length: to - from }, (_, i) => from + i);
  const span = (to - from) * 60;
  const ROW = 52; // px per hour

  const order = Array.from({ length: 7 }, (_, i) => (weekStartsOn + i) % 7);
  // Ended series are drawn but NOT counted. "15 classes a week" has to be the
  // number the studio is actually running, or it is a worse answer than none.
  const running = blocks.filter((b) => !b.isEnded);
  const perDay = order.map((d) => running.filter((b) => b.day === d).length);
  const endedCount = new Set(blocks.filter((b) => b.isEnded).map((b) => b.id)).size;

  // One swatch per class type actually on the grid.
  const key = new Map<string, { name: string; color: string }>();
  for (const b of running) {
    const id = b.class_type_id ?? "none";
    if (!key.has(id)) {
      key.set(id, {
        name: b.class_type_name ?? "No class type",
        color: b.class_type_color ?? "var(--ink-3)",
      });
    }
  }

  const soon = new Date(`${today}T00:00:00Z`);
  soon.setUTCDate(soon.getUTCDate() + 30);
  const soonKey = soon.toISOString().slice(0, 10);

  return (
    <div>
      {/* The number a studio wants when it is deciding whether to add a midday
          class, above the thing it would be adding it to. */}
      <div className="mb-4 flex flex-wrap items-baseline gap-x-6 gap-y-1">
        <p className="text-[13px] leading-[20px] text-ink-2">
          <span className="num text-[17px] font-semibold text-ink">{running.length}</span>{" "}
          {running.length === 1 ? "class" : "classes"} a week
          {series.length - endedCount > 0 && (
            <> from <span className="num text-ink">{series.length - endedCount}</span>{" "}
              series</>
          )}
          {endedCount > 0 && (
            <span className="text-ink-3">
              {" "}· <span className="num">{endedCount}</span> ended, not counted
            </span>
          )}
        </p>
        {key.size > 0 && (
          <ul className="flex flex-wrap items-center gap-x-4 gap-y-1">
            {[...key.entries()].map(([id, k]) => (
              <li key={id} className="flex items-center gap-1.5 text-[12px] leading-4 text-ink-2">
                {/* A hairline round the swatch, because a studio's own colour
                    cannot be guaranteed 3:1 against the page and a shape that
                    disappears is not a key. */}
                <span aria-hidden className="h-3 w-3 rounded-[3px] border border-line-2"
                      style={{ background: k.color }} />
                {k.name}
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="overflow-x-auto rounded-xl border border-line bg-surface">
        <div className="min-w-[720px]">
          {/* Day headers, each carrying its own count. */}
          <div className="grid border-b border-line"
               style={{ gridTemplateColumns: `56px repeat(7, minmax(0, 1fr))` }}>
            <div />
            {order.map((d, i) => (
              <div key={d} className="border-l border-line px-2 py-2 text-center">
                <div className="text-[12.5px] font-medium leading-4 text-ink">{DAYS[d].short}</div>
                <div className="num text-[11px] leading-4 text-ink-3">
                  {perDay[i] === 0 ? "—" : perDay[i]}
                </div>
              </div>
            ))}
          </div>

          <div className="grid" style={{ gridTemplateColumns: `56px repeat(7, minmax(0, 1fr))` }}>
            {/* The hour gutter. */}
            <div>
              {hours.map((h) => (
                <div key={h} className="num border-b border-line pr-2 pt-1 text-right
                                        text-[11px] leading-4 text-ink-3"
                     style={{ height: ROW }}>
                  {String(h).padStart(2, "0")}:00
                </div>
              ))}
            </div>

            {order.map((d) => (
              <div key={d} className="relative border-l border-line"
                   style={{ height: hours.length * ROW }}>
                {hours.map((h) => (
                  <div key={h} className="border-b border-line" style={{ height: ROW }} />
                ))}
                {blocks.filter((b) => b.day === d).map((b) => {
                  const ended = b.isEnded;
                  const ending = !ended && b.ends_on !== null && b.ends_on <= soonKey;
                  const noRoom = b.room_name === null;
                  const colour = b.class_type_color ?? "var(--ink-3)";
                  return (
                    <Link
                      key={`${b.id}-${d}`}
                      href={`/series/${b.id}`}
                      title={`${b.name} · ${hhmm(b.start)}–${hhmm(b.end)}${
                        b.room_name ? ` · ${b.room_name}` : " · no room"}`}
                      className="absolute left-0.5 right-0.5 overflow-hidden rounded-md
                                 px-1.5 py-1 hover:brightness-[0.97]"
                      style={{
                        top: ((b.start - from * 60) / span) * (hours.length * ROW),
                        height: Math.max(22, ((b.end - b.start) / span) * (hours.length * ROW) - 2),
                        // The class type's own colour TINTS the block and sets
                        // the stripe; it never sits behind the text. Ink on a
                        // 14% tint measures 12.43:1 against the worst possible
                        // colour a studio could pick, which a filled block in an
                        // arbitrary hex could not promise.
                        // ENDED IS DRAWN GREY, NOT FADED. Opacity on text is a
                        // contrast change, not a styling choice: at 0.5 the
                        // label measured 2.27:1 on its own tint, against a 4.5
                        // floor. Muting the TINT instead keeps the ink at full
                        // strength and still reads as "not running any more".
                        background: ended
                          ? "color-mix(in srgb, var(--ink-3) 10%, var(--surface))"
                          : `color-mix(in srgb, ${colour} 14%, var(--surface))`,
                        borderLeft: `3px solid ${ended ? "var(--ink-3)" : colour}`,
                        outline: noRoom ? "1px dashed var(--coral)" : undefined,
                        outlineOffset: "-1px",
                      }}
                    >
                      <div className={`truncate text-[11.5px] font-medium leading-[14px] ${
                        ended ? "text-ink-2 line-through decoration-ink-3" : "text-ink"}`}>
                        {b.name}
                      </div>
                      <div className="num truncate text-[10.5px] leading-[13px] text-ink-2">
                        {hhmm(b.start)}
                        {noRoom && <span className="ml-1 font-sans" style={{ color: "var(--coral)" }}>no room</span>}
                        {ending && <span className="ml-1 font-sans text-ink-2">ends {b.ends_on}</span>}
                        {ended && <span className="ml-1 font-sans text-ink-2">ended</span>}
                      </div>
                    </Link>
                  );
                })}
              </div>
            ))}
          </div>
        </div>
      </div>

      {unplaceable.length > 0 && (
        <p className="mt-3 max-w-[62ch] text-[12.5px] leading-[18px] text-ink-2">
          {unplaceable.length}{" "}
          {unplaceable.length === 1 ? "series repeats" : "series repeat"} in a way this
          grid cannot draw — a weekly rule is what it lays out.{" "}
          {unplaceable.map((s) => (
            <Link key={s.id} href={`/series/${s.id}`}
                  className="text-lime-text underline underline-offset-4">{s.name}</Link>
          )).reduce((a, b) => <>{a}, {b}</>)}
        </p>
      )}
    </div>
  );
}
