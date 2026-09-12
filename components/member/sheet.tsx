"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { haptic } from "@/lib/haptics";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";

/**
 * A bottom sheet for a route that intercepted a tap from inside the app.
 *
 * It rises from the bottom edge over a scrim; it closes on the scrim, on Escape,
 * on the back gesture, or on a downward drag past a threshold — the gestures a
 * phone user reaches for without being told. Closing means `router.back()`,
 * because this is an intercepting route: the URL that opened the sheet is one
 * entry deep, and going back both dismisses the sheet and restores the address
 * underneath. A direct load or refresh never reaches here — it renders the full
 * page instead — so the sheet is always something to step back OUT of.
 *
 * The drag lives on the grab handle and header, not the whole panel, so the
 * body scrolls on its own and only a deliberate pull on the top dismisses.
 */
export default function Sheet({
  children, preset = "warm", accent,
}: {
  children: ReactNode;
  // The sheet renders in the @modal slot, OUTSIDE MemberShell, so the studio's
  // theme vars are not on an ancestor — they must be applied here or the panel
  // falls back to Studiior's lime. Custom properties inherit through the DOM to
  // the fixed scrim and panel, so one wrapper themes both.
  preset?: PresetKey;
  accent?: string | null;
}) {
  const router = useRouter();
  const vars = themeVars(preset, accent ?? neutralAccent(preset)) as React.CSSProperties;
  const [closing, setClosing] = useState(false);
  const panel = useRef<HTMLDivElement>(null);
  const drag = useRef<{ y: number; active: boolean }>({ y: 0, active: false });
  const [dragY, setDragY] = useState(0);

  function close() {
    if (closing) return;
    setClosing(true);
    haptic("tap");
    // Let the down-animation play, then step back out of the intercepted route.
    window.setTimeout(() => router.back(), 190);
  }

  // Escape closes, and the body behind the sheet is locked from scrolling while
  // it is open so a flick does not move the page underneath.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function onHandleStart(e: React.TouchEvent) {
    drag.current = { y: e.touches[0].clientY, active: true };
  }
  function onHandleMove(e: React.TouchEvent) {
    if (!drag.current.active) return;
    const dy = e.touches[0].clientY - drag.current.y;
    setDragY(Math.max(0, dy)); // only downward
  }
  function onHandleEnd() {
    if (!drag.current.active) return;
    drag.current.active = false;
    if (dragY > 110) close();
    else setDragY(0); // spring back
  }

  return (
    <div style={vars}>
      <div
        className={closing ? "m-sheet-scrim m-sheet-scrim-closing" : "m-sheet-scrim"}
        onClick={close}
        aria-hidden
      />
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        className={closing ? "m-sheet m-sheet-closing" : "m-sheet"}
        style={dragY ? { transform: `translateY(${dragY}px)`, transition: drag.current.active ? "none" : undefined } : undefined}
      >
        <div
          onTouchStart={onHandleStart}
          onTouchMove={onHandleMove}
          onTouchEnd={onHandleEnd}
          style={{ touchAction: "none" }}
        >
          <div className="m-sheet-grab" aria-hidden />
          <div className="flex justify-end px-4 pt-2">
            <button
              type="button"
              onClick={close}
              aria-label="Close"
              className="m-press flex h-9 items-center rounded-full px-3 text-[13px] font-semibold text-ink-2"
            >
              Done
            </button>
          </div>
        </div>
        <div className="m-sheet-body px-4 pb-6">{children}</div>
      </div>
    </div>
  );
}
