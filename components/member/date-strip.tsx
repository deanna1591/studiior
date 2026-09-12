"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { setNavDir } from "./use-day-nav";
import { haptic } from "@/lib/haptics";

/**
 * The date strip, continuous and flickable.
 *
 * This is the component that decides whether the app reads as an app — the old
 * one moved a week at a time behind two chevrons, when the natural gesture is
 * to scroll horizontally through days. So it is one momentum scroller of many
 * days; a flick carries, scroll-snap lands it on a day, and the selected day is
 * brought into view on load rather than the strip starting at some Monday.
 *
 * Tapping a day is a server navigation like before, but it goes through the
 * shared day-nav so it buzzes, sets the slide direction and pushes ?d=. Each
 * tile is a button rather than a link for exactly that reason — a bare <Link>
 * cannot set the direction flag or fire the haptic in the same gesture.
 *
 * The tile visuals are the week strip's, unchanged: the selected day fills with
 * the accent and takes the one glow in the app; today when unselected is the
 * accent in text; the pip is presence, not a count. Only the container and the
 * navigation changed.
 */
export type StripDay = {
  offset: number;
  dayOfMonth: number;
  weekdayLabel: string;
  hasClasses: boolean;
  isToday: boolean;
  isSelected: boolean;
  isPast: boolean;
  /** Precomputed on the server. A function prop cannot cross into a client
      component, so the href for each day is passed as a string, not built
      here from a hrefFor closure. */
  href: string;
};

export default function DateStrip({
  days,
  selectedOffset,
}: {
  days: StripDay[];
  selectedOffset: number;
}) {
  const router = useRouter();
  const scroller = useRef<HTMLOListElement>(null);
  const selected = useRef<HTMLLIElement>(null);

  // Bring the selected day into view on load, centred, with no animation — it
  // should simply already be where the eye lands, not scroll there. `auto`
  // (instant) rather than `smooth`, and `nearest`/`center` so a flick that the
  // browser is mid-settling is not yanked.
  useEffect(() => {
    const el = selected.current;
    const box = scroller.current;
    if (!el || !box) return;
    const target = el.offsetLeft - box.clientWidth / 2 + el.clientWidth / 2;
    box.scrollLeft = Math.max(0, target);
  }, [selectedOffset]);

  function go(d: StripDay) {
    if (d.offset === selectedOffset) return;
    haptic("tap");
    setNavDir(d.offset > selectedOffset ? "fwd" : "back");
    router.push(d.href, { scroll: false });
  }

  return (
    <ol ref={scroller} className="m-strip -mx-4 px-4 pb-1" aria-label="Choose a day">
      {days.map((d) => (
        <li key={d.offset} ref={d.isSelected ? selected : undefined} className="shrink-0">
          <button
            type="button"
            onClick={() => go(d)}
            aria-current={d.isSelected ? "date" : undefined}
            aria-label={`${d.weekdayLabel} ${d.dayOfMonth}${d.hasClasses ? ", has classes" : ", no classes"}`}
            // 52px wide × 64px tall — comfortably over the 44 floor the old
            // ~43px tiles sat just under.
            className="m-press flex w-[52px] flex-col items-center gap-1 rounded-2xl py-2.5"
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
            <span
              aria-hidden
              className="h-1 w-1 rounded-full"
              style={{
                background: !d.hasClasses
                  ? "transparent"
                  : d.isSelected
                  ? "var(--accent-on-solid)"
                  : "var(--lime-text)",
              }}
            />
          </button>
        </li>
      ))}
    </ol>
  );
}
