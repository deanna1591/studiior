"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { isNewVersion, isSuppressedPath } from "@/lib/version-check";

/**
 * Decision 107: when a new version of the app has been deployed, an open app
 * shows a small bar within a minute of the deployment; tapping Refresh reloads
 * once. The app never reloads on its own, and the bar is suppressed while a
 * member is in checkout or mid-form. The build id of the deploy that served the
 * page is the baseline; a changed id from the polled endpoint means a new deploy.
 */
export default function UpdatePrompt() {
  const pathname = usePathname();
  const [baseline, setBaseline] = useState<string | null>(null);
  const [current, setCurrent] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const check = async () => {
      try {
        const r = await fetch("/api/version", { cache: "no-store" });
        const d = (await r.json()) as { build?: string };
        if (!alive || !d.build) return;
        setBaseline((b) => b ?? d.build!);
        setCurrent(d.build);
      } catch {
        /* a failed poll never nags */
      }
    };
    check();
    const iv = setInterval(check, 60_000);
    const onVisible = () => { if (!document.hidden) check(); };
    window.addEventListener("focus", check);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      alive = false;
      clearInterval(iv);
      window.removeEventListener("focus", check);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);

  const focusedInForm =
    typeof document !== "undefined" &&
    document.activeElement != null &&
    ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName);

  if (!isNewVersion(baseline, current) || isSuppressedPath(pathname) || focusedInForm) return null;

  return (
    <div
      className="fixed inset-x-0 top-0 z-50 flex items-center justify-center px-4"
      style={{ paddingTop: "calc(env(safe-area-inset-top, 0px) + 8px)" }}
      role="status"
    >
      <div className="flex items-center gap-3 rounded-full bg-ink px-4 py-2 shadow-lg">
        <span className="text-[13px] font-medium" style={{ color: "var(--surface)" }}>A new version is ready</span>
        <button
          type="button"
          onClick={() => window.location.reload()}
          className="rounded-full px-3 py-1 text-[13px] font-bold"
          style={{ background: "var(--surface)", color: "var(--ink)" }}
        >
          Refresh
        </button>
      </div>
    </div>
  );
}
