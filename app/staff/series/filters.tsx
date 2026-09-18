"use client";

import { useRouter, useSearchParams } from "next/navigation";

/**
 * Filter the standing timetable by tier and by class type, combinable.
 *
 * The value lives in the URL (`?tier=flex&type=<id>`), never in component state
 * or the cookie: a filter should be shareable and survive a refresh, and a
 * hidden filter that persists is how someone decides half their series have
 * vanished. The list-vs-grid cookie is a display preference; which slice of the
 * timetable you are looking at is not.
 *
 * The tier pills only appear when the studio uses tiers at all — the same
 * `guarantees_enabled OR flex_enabled` the tier marks use, so the pills cannot
 * offer a filter for a dimension the rows do not show.
 */
const TIERS: [string, string][] = [["", "All"], ["core", "Core"], ["flex", "Flex"], ["always", "Always"]];

export default function SeriesFilters({
  showTier, types, tier, type,
}: {
  showTier: boolean;
  types: { id: string; name: string }[];
  tier: string;
  type: string;
}) {
  const router = useRouter();
  const sp = useSearchParams();
  const go = (key: string, val: string) => {
    const p = new URLSearchParams(sp.toString());
    if (val) p.set(key, val); else p.delete(key);
    router.push(`/series?${p.toString()}`);
  };
  // The staff pill: rounded-full, ink fill when active (white on near-black,
  // well above the floor), a hairline otherwise.
  const pill = (active: boolean) =>
    `rounded-full px-3 py-1 text-[12.5px] leading-4 ${
      active ? "bg-ink text-paper" : "border border-line-2 text-ink-2 hover:text-ink"
    }`;

  return (
    <div className="mb-5 flex flex-wrap items-center gap-x-5 gap-y-2">
      {showTier && (
        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filter by tier">
          {TIERS.map(([v, label]) => (
            <button key={v || "all"} type="button" onClick={() => go("tier", v)}
                    aria-pressed={(tier || "") === v} className={pill((tier || "") === v)}>
              {label}
            </button>
          ))}
        </div>
      )}
      <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filter by class type">
        <button type="button" onClick={() => go("type", "")} aria-pressed={!type} className={pill(!type)}>
          All types
        </button>
        {types.map((t) => (
          <button key={t.id} type="button" onClick={() => go("type", t.id)}
                  aria-pressed={type === t.id} className={pill(type === t.id)}>
            {t.name}
          </button>
        ))}
      </div>
    </div>
  );
}
