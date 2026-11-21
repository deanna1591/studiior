"use client";

import { useEffect, useState } from "react";
import { Sheet } from "@/components/staff/book-member";
import {
  instructorBookingOptions, instructorBookMember, instructorSearchMembers,
} from "@/app/member/instructor/actions";
import type { MemberHit } from "@/app/staff/members/book-actions";

/** Decision 100 amendment (b): the class's own instructor adds a member to the
 *  class they are teaching. The shared Sheet shows the late-add banner and, for a
 *  free class that owes the reservation fee, the end-of-day due line (no switch;
 *  the instructor cannot waive). */
export function InstructorAddMember({ occurrenceId, timeZone, timeFormat }: {
  occurrenceId: string; timeZone: string; timeFormat: "24h" | "12h";
}) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState("");
  const [hits, setHits] = useState<MemberHit[]>([]);
  const [picked, setPicked] = useState<MemberHit | null>(null);

  useEffect(() => {
    if (!open || picked) return;
    const t = setTimeout(() => { instructorSearchMembers(occurrenceId, term).then(setHits); }, 200);
    return () => clearTimeout(t);
  }, [term, open, picked, occurrenceId]);

  return (
    <>
      <button onClick={() => setOpen(true)}
              className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink">
        Add a member
      </button>
      {open && !picked && (
        <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true">
          <button className="absolute inset-0 bg-black/30" aria-label="Close" onClick={() => { setOpen(false); setTerm(""); }} />
          <div className="relative w-full max-w-md rounded-t-2xl bg-surface p-5 shadow-xl sm:rounded-2xl">
            <h2 className="text-[17px] font-semibold text-ink">Add a member</h2>
            <input autoFocus placeholder="Search by name or email"
                   className="mt-3 w-full rounded-lg border border-line-2 bg-paper px-3 py-2 text-[14px] text-ink"
                   value={term} onChange={(e) => setTerm(e.target.value)} />
            <ul className="mt-2 max-h-64 overflow-y-auto">
              {hits.map((h) => (
                <li key={h.id}>
                  <button onClick={() => setPicked(h)}
                          className="w-full rounded-lg px-3 py-2 text-left text-[14px] text-ink hover:bg-paper">
                    {h.name} <span className="text-ink-3">· {h.email}</span>
                  </button>
                </li>
              ))}
              {term.trim().length >= 2 && hits.length === 0 && (
                <li className="px-3 py-2 text-[13px] text-ink-3">No members found.</li>
              )}
            </ul>
            <button onClick={() => { setOpen(false); setTerm(""); }}
                    className="mt-2 rounded-lg border border-line-2 bg-surface px-4 py-2 text-[13px] text-ink">Cancel</button>
          </div>
        </div>
      )}
      {open && picked && (
        <Sheet timeZone={timeZone} timeFormat={timeFormat} memberId={picked.id} occurrenceId={occurrenceId}
               optionsFn={instructorBookingOptions} bookFn={instructorBookMember}
               onClose={() => { setOpen(false); setPicked(null); setTerm(""); }} />
      )}
    </>
  );
}
