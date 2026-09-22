"use client";

import { useRouter } from "next/navigation";

/**
 * Decision 37 — the instructor-column default, made a visible control.
 *
 * Day view shows only the people teaching that day (a column per instructor does
 * not scale — the lesson from the migration that added columns). That default
 * stays; this is the switch to see everyone, which is what you need to drag a
 * class onto somebody not teaching yet. It was reachable only through a "Showing
 * the N…" text link; now it is a segmented toggle in the toolbar beside the
 * instructor filter, carried in the URL (?all=1) like the filter, so it survives
 * Back/Next and the view toggle.
 */
export default function ShowAllToggle({
  anchor, view, showAll, instructor,
}: {
  anchor: string;
  view: "day" | "week" | "month";
  showAll: boolean;
  instructor: string;
}) {
  const router = useRouter();
  const go = (all: boolean) => {
    const f = instructor ? `&instructor=${encodeURIComponent(instructor)}` : "";
    router.push(`/schedule?d=${anchor}&view=${view}${f}${all ? "&all=1" : ""}`);
  };
  const seg = (active: boolean) =>
    `m-tap px-2.5 py-1 text-[12.5px] font-medium ${active ? "" : "text-ink-2"}`;
  return (
    <div className="inline-flex items-center rounded-lg border border-line-2 p-0.5"
         role="group" aria-label="Which instructors to show">
      <button type="button" onClick={() => go(false)} aria-pressed={!showAll}
              className={`${seg(!showAll)} rounded-[6px]`}
              style={!showAll ? { background: "var(--ink)", color: "var(--paper)" } : undefined}>
        Teaching today
      </button>
      <button type="button" onClick={() => go(true)} aria-pressed={showAll}
              className={`${seg(showAll)} rounded-[6px]`}
              style={showAll ? { background: "var(--ink)", color: "var(--paper)" } : undefined}>
        Everyone
      </button>
    </div>
  );
}
