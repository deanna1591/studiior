"use client";

import { useEffect, useState } from "react";

/**
 * The shared spine of day navigation: the strip and the swipe wrapper both
 * change the day the same way, so the direction flag and the entrance class
 * live here rather than being written twice.
 *
 * A day change is a server navigation (?d=N), which keeps RLS, the SQL and the
 * two-hop fetch exactly as they are. The push/pop feel is an entrance slide on
 * the ARRIVING day — set the direction just before navigating, read it on the
 * next render, clear it. Reliable over a round trip in a way that animating the
 * outgoing frame is not.
 */
const NAV_KEY = "m-navdir";
export type NavDir = "fwd" | "back";

export function setNavDir(dir: NavDir): void {
  try {
    sessionStorage.setItem(NAV_KEY, dir);
  } catch {
    // Private mode, storage disabled: the slide is skipped, the nav still works.
  }
}

/**
 * The class to hang on the day's content wrapper. Reads the flag the last
 * navigation left and applies the matching entrance class, clearing the flag so
 * it fires once.
 *
 * Set in an EFFECT, not during render: reading sessionStorage while rendering
 * makes the server ("" — no storage) and the client (the flag) disagree, which
 * is a hydration error. The effect runs after mount, so the first paint carries
 * no class on both sides and the slide is added a frame later — imperceptible
 * against a 240ms slide. It re-runs on every day change because the content is
 * keyed by the day and therefore remounts; a soft navigation would otherwise
 * keep a same-position component mounted and never re-run an empty-deps effect.
 * A normal load (no flag) stays "" and does not animate.
 */
export function useEntranceClass(): string {
  const [cls, setCls] = useState("");
  useEffect(() => {
    let dir: string | null = null;
    try {
      dir = sessionStorage.getItem(NAV_KEY);
      if (dir) sessionStorage.removeItem(NAV_KEY);
    } catch {
      /* no storage, no slide */
    }
    if (dir === "fwd") setCls("m-day-enter m-day-enter-fwd");
    else if (dir === "back") setCls("m-day-enter m-day-enter-back");
  }, []);
  return cls;
}
