"use client";

import { useState, useEffect, useRef } from "react";
import { useRouter, useSearchParams, usePathname } from "next/navigation";

/**
 * Decision 105: the Members list search box. Filters as you type on name, email
 * and phone digits, and keeps the search in the URL (replace, not push) so a
 * refresh and Back return to the same view without stacking history.
 */
export default function MembersSearch({ initial }: { initial: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  const [q, setQ] = useState(initial);
  const first = useRef(true);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (first.current) { first.current = false; return; }
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      const p = new URLSearchParams(params.toString());
      if (q.trim()) p.set("q", q.trim()); else p.delete("q");
      router.replace(`${pathname}?${p.toString()}`, { scroll: false });
    }, 250);
    return () => { if (timer.current) clearTimeout(timer.current); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  return (
    <div className="relative">
      <input
        type="search"
        inputMode="search"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search name, email or phone"
        aria-label="Search members by name, email or phone"
        className="w-full rounded-lg border border-line bg-surface px-3 py-2 text-[14px] text-ink placeholder:text-ink-3 focus:border-ink-3 focus:outline-none"
      />
    </div>
  );
}
