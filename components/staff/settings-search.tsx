"use client";

import { useRouter } from "next/navigation";
import { useRef, useState } from "react";
import { searchSettings } from "@/lib/settings-registry";
import type { SettingEntry } from "@/lib/settings-registry";

/**
 * Decision 71 — the Settings home search box. Filters the registry client-side
 * as you type (no RPC); Enter or click jumps to the setting's page and section,
 * where a brief highlight marks it. Owner-only matches carry a muted tag.
 */
export default function SettingsSearch() {
  const router = useRouter();
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const boxRef = useRef<HTMLDivElement>(null);

  const matches = searchSettings(q);

  function go(s: SettingEntry) {
    const dest = s.standalone ?? `${s.page}#${s.anchor}`;
    setOpen(false);
    setQ("");
    router.push(dest);
  }

  return (
    <div ref={boxRef} className="relative max-w-2xl">
      <input
        type="search"
        value={q}
        placeholder="Search settings — try “cut-off”, “pay”, “gcash”…"
        aria-label="Search settings"
        className="w-full rounded border border-line bg-surface px-3.5 py-2.5 text-[14px] text-ink outline-none placeholder:text-ink-3"
        onChange={(e) => { setQ(e.target.value); setOpen(true); setActive(0); }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 120)}
        onKeyDown={(e) => {
          if (!matches.length) return;
          if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(a + 1, matches.length - 1)); }
          else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
          else if (e.key === "Enter") { e.preventDefault(); go(matches[active]); }
          else if (e.key === "Escape") { setOpen(false); }
        }}
      />
      {open && matches.length > 0 && (
        <ul className="absolute z-20 mt-1 w-full overflow-hidden rounded border border-line bg-surface shadow-lg">
          {matches.map((s, i) => (
            <li key={s.id}>
              <button
                type="button"
                className={`flex w-full items-center justify-between gap-3 px-3.5 py-2 text-left hover:bg-paper ${i === active ? "bg-paper" : ""}`}
                onMouseEnter={() => setActive(i)}
                onMouseDown={(e) => { e.preventDefault(); go(s); }}
              >
                <span className="min-w-0">
                  <span className="block truncate text-[14px] text-ink">{s.label}</span>
                  <span className="block truncate text-[12px] text-ink-3">{groupLabel(s.group)}</span>
                </span>
                {s.ownerOnly && <span className="shrink-0 text-[11px] text-ink-3">Owner only</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function groupLabel(id: string): string {
  // Small local map so the suggestion sub-line reads the group's name.
  const m: Record<string, string> = {
    studio: "Studio",
    booking: "Booking & cancellation",
    classes: "Classes & instructors",
    memberships: "Memberships & payments",
    communications: "Communications",
    integrations: "Apps & integrations",
  };
  return m[id] ?? id;
}
