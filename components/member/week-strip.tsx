import Link from "next/link";
import { Icon } from "./icons";

/**
 * The week, as seven cards.
 *
 * This is the component that decides whether the app reads as an app. A
 * previous/next pair around a single day label is a webpage's answer: it tells
 * you where you are and nothing about where you might go. Seven columns tell
 * you the shape of the week — which days have classes, how far Saturday is,
 * that Thursday is empty — before you tap anything.
 *
 * EACH DAY IS A CARD, not a bare number. On the washed page a plain numeral has
 * nothing holding it, and seven of them read as a line of text; a white tile
 * reads as seven things you can press. The selected one fills with the accent
 * and takes a coloured glow — the only glow in the app, spent here because this
 * is the control a member touches most.
 *
 * SELECTED, not today, takes the fill. The member is navigating, and the filled
 * tile has to answer "which day am I looking at". Today is still marked when it
 * is not the one selected, in accent text, so the two never look the same.
 *
 * The pip under a day is presence, not count. A number there would be a second
 * thing to read in a row of seven, and the count is on the screen below.
 */
export type WeekDay = {
  /** Midnight in the studio's zone, as an offset in days from today. */
  offset: number;
  dayOfMonth: number;
  /** MON…SUN, already localised. */
  weekdayLabel: string;
  hasClasses: boolean;
  isToday: boolean;
  isSelected: boolean;
  isPast: boolean;
};

export default function WeekStrip({
  days, hrefFor,
}: {
  days: WeekDay[];
  hrefFor: (offset: number) => string;
}) {
  return (
    <ol className="flex items-stretch gap-1.5">
      {days.map((d) => (
        <li key={d.offset} className="flex-1">
          <Link
            href={hrefFor(d.offset)}
            aria-current={d.isSelected ? "date" : undefined}
            aria-label={`${d.weekdayLabel} ${d.dayOfMonth}${d.hasClasses ? ", has classes" : ", no classes"}`}
            className="flex flex-col items-center gap-1 rounded-2xl py-2.5"
            style={
              d.isSelected
                ? {
                    background: "var(--accent-solid)",
                    color: "var(--accent-on-solid)",
                    boxShadow: "0 6px 16px -4px color-mix(in srgb, var(--accent-solid) 45%, transparent)",
                  }
                : { background: "var(--surface)", boxShadow: "0 1px 3px rgb(26 21 18 / 0.05)" }
            }
          >
            <span
              className="text-[10px] font-semibold uppercase leading-3 tracking-[0.05em]"
              style={d.isSelected ? undefined : { color: "var(--ink-3)" }}
            >
              {d.weekdayLabel}
            </span>
            <span
              className="num text-[15px] font-bold leading-5"
              style={
                d.isSelected ? undefined
                : d.isToday ? { color: "var(--lime-text)" }
                : d.isPast ? { color: "var(--ink-3)" }
                : { color: "var(--ink)" }
              }
            >
              {d.dayOfMonth}
            </span>
            {/* Always rendered, so a row never changes height when a day is
                empty. On the filled tile it takes the ink measured on that
                fill, because a --accent-solid pip on --accent-solid is
                invisible. */}
            <span
              aria-hidden
              className="h-1 w-1 rounded-full"
              style={{
                background: !d.hasClasses ? "transparent"
                  : d.isSelected ? "var(--accent-on-solid)"
                  // --lime-text, not --accent-solid: on the white tile a light
                  // accent is 1.23 and the pip vanishes. On the FILLED tile
                  // the ground is the accent itself, so the measured on-solid
                  // ink is the right one there.
                  : "var(--lime-text)",
              }}
            />
          </Link>
        </li>
      ))}
    </ol>
  );
}

/**
 * The same information over a whole month.
 *
 * It exists because the mockup draws a Week/Month toggle, and a segmented
 * control with a dead half is exactly the decorative control this build refuses
 * to ship. What it is actually FOR: the week strip answers "what is on this
 * week" and cannot answer "when is the next Saturday class" — over a month the
 * pips make the studio's rhythm visible at a glance.
 *
 * Tapping a day selects it and drops back to the week, because the list below
 * is still a day's worth of classes and the week is the better frame once you
 * know which day you want.
 */
export type MonthDay = WeekDay & { inMonth: boolean };

export function MonthGrid({
  days, hrefFor,
}: {
  days: MonthDay[];
  hrefFor: (offset: number) => string;
}) {
  return (
    <div className="m-card p-3">
      <ol className="grid grid-cols-7 gap-1" role="grid">
        {["M", "T", "W", "T", "F", "S", "S"].map((l, i) => (
          <li key={i} className="pb-1 text-center text-[10px] font-semibold uppercase leading-4 tracking-[0.05em] text-ink-3">
            {l}
          </li>
        ))}
        {days.map((d) => (
          <li key={d.offset}>
            <Link
              href={hrefFor(d.offset)}
              aria-current={d.isSelected ? "date" : undefined}
              aria-label={`${d.weekdayLabel} ${d.dayOfMonth}${d.hasClasses ? ", has classes" : ", no classes"}`}
              className={`flex h-11 flex-col items-center justify-center gap-1 rounded-xl ${d.inMonth ? "" : "opacity-35"}`}
              style={
                d.isSelected
                  ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
                  : undefined
              }
            >
              <span
                className="num text-[13px] font-semibold leading-4"
                style={
                  d.isSelected ? undefined
                  : d.isToday ? { color: "var(--lime-text)" }
                  : d.isPast ? { color: "var(--ink-3)" }
                  : { color: "var(--ink)" }
                }
              >
                {d.dayOfMonth}
              </span>
              <span
                aria-hidden
                className="h-1 w-1 rounded-full"
                style={{
                  background: !d.hasClasses ? "transparent"
                    : d.isSelected ? "var(--accent-on-solid)"
                    // --lime-text, not --accent-solid: on the white tile a light
                  // accent is 1.23 and the pip vanishes. On the FILLED tile
                  // the ground is the accent itself, so the measured on-solid
                  // ink is the right one there.
                  : "var(--lime-text)",
                }}
              />
            </Link>
          </li>
        ))}
      </ol>
    </div>
  );
}
