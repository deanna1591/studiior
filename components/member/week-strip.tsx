import Link from "next/link";
import { Icon } from "./icons";

/**
 * The week, as a strip.
 *
 * This is the component that decides whether the app reads as an app. A
 * previous/next pair around a single day label is a webpage's answer: it tells
 * you where you are and nothing about where you might go. Seven columns tell
 * you the shape of the week — which days have classes, how far Saturday is,
 * that Thursday is empty — before you tap anything.
 *
 * SELECTED, not today, takes the filled circle. The member is navigating, and
 * the filled disc has to answer "which day am I looking at". Today is still
 * marked when it is not the one selected, in accent text with its label above
 * it, so the two states never look the same.
 *
 * The dot under a day is presence, not count. A number there would be a second
 * thing to read in a row of seven, and the count is on the screen below.
 */
export type WeekDay = {
  /** Midnight in the studio's zone, as an offset in days from today. */
  offset: number;
  /** 1–31, in the studio's zone. */
  dayOfMonth: number;
  /** MON…SUN, already localised. */
  weekdayLabel: string;
  hasClasses: boolean;
  isToday: boolean;
  isSelected: boolean;
  isPast: boolean;
};

export default function WeekStrip({
  days, monthLabel, hrefFor, prevHref, nextHref,
}: {
  days: WeekDay[];
  monthLabel: string;
  hrefFor: (offset: number) => string;
  prevHref: string;
  nextHref: string;
}) {
  return (
    <section aria-label="Choose a day" className="mb-4">
      <div className="mb-2 flex items-center justify-between">
        <h2 className="m-body font-medium text-ink">{monthLabel}</h2>
        <div className="flex items-center gap-1.5">
          <Link
            href={prevHref}
            aria-label="Previous week"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-line-2 bg-surface text-ink-2"
          >
            <Icon name="chevron-left" size={18} />
          </Link>
          <Link
            href={nextHref}
            aria-label="Next week"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-line-2 bg-surface text-ink-2"
          >
            <Icon name="chevron-right" size={18} />
          </Link>
        </div>
      </div>

      <ol className="flex items-stretch justify-between">
        {days.map((d) => (
          <li key={d.offset} className="flex-1">
            <Link
              href={hrefFor(d.offset)}
              aria-current={d.isSelected ? "date" : undefined}
              aria-label={`${d.weekdayLabel} ${d.dayOfMonth}${d.hasClasses ? ", has classes" : ", no classes"}`}
              className="flex flex-col items-center gap-1 py-1"
            >
              <span
                className={`text-[11px] font-medium uppercase leading-3 tracking-[0.04em] ${
                  d.isSelected ? "text-ink" : d.isPast ? "text-ink-3" : "text-ink-3"
                }`}
              >
                {d.weekdayLabel}
              </span>

              {/* 36px disc inside a 44px column: the tap target is the whole
                  cell, and the disc is what it looks like. */}
              <span
                className="num flex h-9 w-9 items-center justify-center rounded-full text-[15px] font-medium"
                style={
                  d.isSelected
                    ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                    : d.isToday
                      ? { color: "var(--lime-text)", fontWeight: 700 }
                      : undefined
                }
              >
                <span className={d.isSelected || d.isToday ? "" : d.isPast ? "text-ink-3" : "text-ink"}>
                  {d.dayOfMonth}
                </span>
              </span>

              {/* Always rendered, so the row never changes height when a day
                  has nothing on. */}
              <span
                aria-hidden
                className="h-1.5 w-1.5 rounded-full"
                // One colour for every dot. The selected day's dot was given
                // the accent's text colour to contrast against the filled
                // circle — but it sits below the circle on the page, not on
                // it, so all that achieved was one grey dot in a row of
                // accent ones, which reads as "this day is different".
                style={{ background: d.hasClasses ? "var(--accent-solid)" : "transparent" }}
              />
            </Link>
          </li>
        ))}
      </ol>
    </section>
  );
}
