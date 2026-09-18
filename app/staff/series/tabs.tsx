"use client";

import { useRouter, useSearchParams } from "next/navigation";

/**
 * List or Grid, remembered.
 *
 * The choice is written to a cookie rather than localStorage so the SERVER
 * knows it on the next render. localStorage would mean the page arrives as a
 * list every time and flips to a grid after hydration, which is a flash on
 * every visit for a preference that never changes.
 */
export default function ViewTabs({ view }: { view: "list" | "grid" }) {
  const router = useRouter();
  const sp = useSearchParams();
  const pick = (v: "list" | "grid") => {
    // A year, path-scoped, lax: it is a display preference, not a session.
    document.cookie = `series_view=${v}; path=/; max-age=31536000; samesite=lax`;
    // Preserve the filter (?tier/?type/?ended) across the view toggle — the view
    // is a display choice, the filter is what you are looking at.
    const p = new URLSearchParams(sp.toString());
    p.set("view", v);
    router.push(`/series?${p.toString()}`);
  };
  return (
    <div className="inline-flex rounded-lg border border-line-2 p-0.5" role="tablist">
      {(["list", "grid"] as const).map((v) => (
        <button
          key={v}
          role="tab"
          aria-selected={view === v}
          onClick={() => pick(v)}
          className={`rounded-md px-3 py-1 text-[13px] leading-[18px] capitalize ${
            view === v ? "bg-ink text-paper" : "text-ink-2 hover:text-ink"
          }`}
        >
          {v}
        </button>
      ))}
    </div>
  );
}
