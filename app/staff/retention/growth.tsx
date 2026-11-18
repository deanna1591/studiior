"use client";

import { useState } from "react";
import Link from "next/link";
import { CoachProposals } from "@/components/dashboard/growth-card";
import type { GrowthPayload } from "@/lib/dashboard";

/**
 * Decision 106 — the growth section on the Retention page. The same proposals
 * as the dashboard card (Make core / Make flex), plus the two things the page
 * surfaces that the card does not: slots members want more of ("Add a class
 * here") and members booked often but not lately (to nudge).
 */
function Copy({ value, children }: { value: string; children: React.ReactNode }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button"
      onClick={async () => { try { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1500); } catch {} }}
      className="rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
      {done ? "Copied" : children}
    </button>
  );
}

export default function GrowthSection({ payload }: { payload: GrowthPayload | null }) {
  if (!payload || payload.coaches.length === 0) return null;
  const { coaches, wanted, nudge, summary } = payload;
  return (
    <section id="growth" className="mb-7 scroll-mt-20">
      <div className="mb-2 flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 className="text-[13px] font-semibold text-ink">Grow your week</h2>
        <span className="text-[12px] text-ink-3">reviewed every Monday</span>
      </div>
      {summary?.text && <p className="mb-3 text-[13px] text-ink-2">{summary.text}</p>}

      <CoachProposals coaches={coaches} />

      {wanted.length > 0 && (
        <div className="mt-6">
          <h3 className="mb-1 text-[13px] font-semibold text-ink">Classes members want more of</h3>
          <ul>
            {wanted.map((w) => (
              <li key={w.series_id} className="flex items-center justify-between gap-2 border-b border-line py-2">
                <span className="min-w-0 truncate text-[13px] text-ink">
                  <span className="num text-ink-2">{w.day_name} {w.time}</span>{" "}
                  {w.class_name} with {w.instructor_name}
                  <span className="ml-1 text-[12px] text-ink-3">· {w.reason}</span>
                </span>
                <Link href="/schedule"
                  className="shrink-0 rounded border border-line-2 px-2 py-0.5 text-[12px] text-ink-2 hover:text-ink">
                  Add a class here
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}

      {nudge.length > 0 && (
        <div className="mt-6">
          <h3 className="mb-1 text-[13px] font-semibold text-ink">Booked often, not lately</h3>
          <ul>
            {nudge.map((n) => (
              <li key={n.member_id} className="flex flex-wrap items-center gap-2 border-b border-line py-2">
                <Link href={`/members/${n.member_id}`} className="text-[13px] font-medium text-ink hover:underline">
                  {n.name}
                </Link>
                {n.last_visit && <span className="text-[12px] text-ink-3">last in {n.last_visit}</span>}
                <div className="ml-auto flex items-center gap-2">
                  {n.phone && <Copy value={n.phone}>{n.phone}</Copy>}
                  {n.email && <Copy value={n.email}>Email</Copy>}
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
