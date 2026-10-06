"use client";

import { useEffect, useRef } from "react";

/**
 * Decision 71 — a headed section on a group page. On load, if the URL hash
 * matches this section's id, scroll it into view and flash a brief highlight so
 * a search jump lands somewhere obvious. Pure client behaviour; no state leaves.
 */
export default function SettingsSection({
  id, title, children,
}: { id: string; title: string; children: React.ReactNode }) {
  const ref = useRef<HTMLElement>(null);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (window.location.hash.slice(1) !== id) return;
    const el = ref.current;
    if (!el) return;
    el.scrollIntoView({ behavior: "smooth", block: "start" });
    el.classList.add("settings-flash");
    const t = setTimeout(() => el.classList.remove("settings-flash"), 1600);
    return () => clearTimeout(t);
  }, [id]);

  return (
    <section ref={ref} id={id} className="mb-10 scroll-mt-20 rounded-lg transition-colors">
      <h2 className="section-label text-ink-2">{title}</h2>
      <div className="mt-3">{children}</div>
    </section>
  );
}
