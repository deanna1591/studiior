"use client";

import { useRef, useState, useTransition, type ReactNode } from "react";
import { useRouter, usePathname } from "next/navigation";
import { isSuppressedPath } from "@/lib/version-check";

/**
 * Decision 107: pulling down from the top of a main screen reloads that screen's
 * DATA with a small spinner, the page itself does not reload. It calls
 * router.refresh(), which re-fetches the server component for the current route.
 * Suppressed on checkout and form screens so a stray pull never disturbs them.
 */
export default function PullToRefresh({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [pull, setPull] = useState(0);
  const [isPending, startTransition] = useTransition();
  const startY = useRef<number | null>(null);
  const THRESHOLD = 70;
  const suppressed = isSuppressedPath(pathname);

  const onTouchStart = (e: React.TouchEvent) => {
    startY.current = window.scrollY <= 0 && !suppressed ? e.touches[0].clientY : null;
  };
  const onTouchMove = (e: React.TouchEvent) => {
    if (startY.current == null) return;
    const dy = e.touches[0].clientY - startY.current;
    if (dy > 0 && window.scrollY <= 0) setPull(Math.min(dy * 0.5, 90));
    else setPull(0);
  };
  const onTouchEnd = () => {
    if (pull >= THRESHOLD && !isPending) startTransition(() => router.refresh());
    setPull(0);
    startY.current = null;
  };

  const showSpinner = isPending || pull > 4;
  const y = isPending ? 28 : pull;

  return (
    <div onTouchStart={onTouchStart} onTouchMove={onTouchMove} onTouchEnd={onTouchEnd}>
      {showSpinner && (
        <div
          aria-hidden
          className="pointer-events-none fixed left-1/2 top-0 z-40 -translate-x-1/2"
          style={{ transform: `translate(-50%, ${y}px)`, transition: isPending ? "transform .15s" : undefined }}
          data-testid="ptr-spinner"
        >
          <span
            className="block h-7 w-7 rounded-full border-2"
            style={{
              borderColor: "var(--line-2)",
              borderTopColor: "var(--lime-text)",
              animation: isPending ? "ptr-spin .7s linear infinite" : undefined,
            }}
          />
          <style>{`@keyframes ptr-spin{to{transform:rotate(360deg)}}`}</style>
        </div>
      )}
      {children}
    </div>
  );
}
