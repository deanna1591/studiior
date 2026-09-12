"use client";

import { useRef, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { setNavDir, useEntranceClass } from "./use-day-nav";
import { haptic } from "@/lib/haptics";
import { Icon } from "./icons";

/**
 * The day's classes, made swipeable, and pull-to-refreshable.
 *
 * Two gestures share one touch surface, so they live in one component:
 *  - a horizontal swipe moves between days (left = next, right = previous),
 *    riding the same server nav and entrance slide as a strip tap;
 *  - a downward pull at the very top of the list refreshes it — the app runs
 *    its own, because the browser's native pull-to-refresh is suppressed by
 *    overscroll-behavior so a mis-pull inside the list does not reload the tab.
 *
 * The arriving day slides in from the side the gesture implied (useEntranceClass
 * reads the flag the navigation set). The gesture only commits past a real
 * threshold and only when it is clearly horizontal (or clearly a top pull), so
 * a vertical scroll through the list is never hijacked.
 */
export default function DayView({
  prevHref,
  nextHref,
  children,
}: {
  prevHref: string;
  nextHref: string;
  children: ReactNode;
}) {
  const router = useRouter();
  const entrance = useEntranceClass();

  const start = useRef<{ x: number; y: number; atTop: boolean } | null>(null);
  const axis = useRef<"?" | "x" | "y">("?");
  const [pull, setPull] = useState(0); // px the refresh spinner is dragged down
  const [refreshing, setRefreshing] = useState(false);

  const SWIPE = 56; // px of horizontal travel that commits a day change
  const PULL = 64; // px of downward pull that commits a refresh

  function onTouchStart(e: React.TouchEvent) {
    if (refreshing) return;
    const t = e.touches[0];
    start.current = { x: t.clientX, y: t.clientY, atTop: window.scrollY <= 0 };
    axis.current = "?";
  }

  function onTouchMove(e: React.TouchEvent) {
    if (!start.current || refreshing) return;
    const t = e.touches[0];
    const dx = t.clientX - start.current.x;
    const dy = t.clientY - start.current.y;
    if (axis.current === "?" && Math.abs(dx) + Math.abs(dy) > 8) {
      axis.current = Math.abs(dx) > Math.abs(dy) ? "x" : "y";
    }
    // A downward pull that began at the top drags the spinner in. Damped, so it
    // feels like resistance rather than a free slide.
    if (axis.current === "y" && start.current.atTop && dy > 0) {
      setPull(Math.min(dy * 0.5, PULL + 16));
    }
  }

  function onTouchEnd(e: React.TouchEvent) {
    const s = start.current;
    start.current = null;
    if (!s || refreshing) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - s.x;
    const dy = t.clientY - s.y;

    if (axis.current === "x" && Math.abs(dx) > SWIPE) {
      // Swipe left → the next day; swipe right → the previous one.
      haptic("tap");
      if (dx < 0) {
        setNavDir("fwd");
        router.push(nextHref, { scroll: false });
      } else {
        setNavDir("back");
        router.push(prevHref, { scroll: false });
      }
      return;
    }

    if (pull >= PULL && s.atTop && dy > 0) {
      setRefreshing(true);
      setPull(44);
      haptic("tap");
      router.refresh();
      // The server component re-renders on refresh; this instance stays mounted,
      // so the spinner is retired on a short timer once the data is in flight.
      window.setTimeout(() => {
        setRefreshing(false);
        setPull(0);
      }, 900);
    } else {
      setPull(0);
    }
  }

  return (
    <div
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
      style={{ touchAction: "pan-y" }}
    >
      {/* The refresh spinner, dragged down from behind the top of the list. */}
      <div
        className="m-ptr"
        aria-hidden={!refreshing}
        style={{
          transform: `translateY(${pull}px)`,
          transition: start.current ? "none" : "transform 220ms cubic-bezier(0.22,1,0.36,1)",
          opacity: pull > 4 ? 1 : 0,
        }}
      >
        <Icon name="refresh" size={18} className={refreshing ? "m-ptr-spin" : ""} />
      </div>

      <div className={entrance}>{children}</div>
    </div>
  );
}
