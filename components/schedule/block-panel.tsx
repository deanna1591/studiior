"use client";

import { useEffect, useState, useTransition } from "react";
import { assignInstructor, reassignInstructor, republishShift, openShift } from "@/app/staff/roster/actions";
import { assignCandidates } from "@/app/staff/schedule/actions";
import type { AssignCandidate } from "@/lib/assign";

export type BlockFacts = {
  id: string;
  title: string;
  when: string;
  instructorId: string | null;
  instructorName: string | null;
  bookedCount: number;
  capacity: number;
  waitlistCount: number;
  staffing: "assigned" | "open" | "pending_approval";
  pendingApplications: number;
};

/**
 * The staffing control, inline over the calendar block — the same actions the
 * roster carries, in a second place. Clicking a block opens this rather than
 * navigating, so a class can be staffed, swapped or opened without leaving the
 * week.
 *
 * UNSTAFFED: assign someone, or email qualified instructors again.
 * ASSIGNED: change the instructor (a swap), or unassign (open it as a shift).
 * Both the assign and the swap go through move_occurrence() (the roster's
 * actions), so the validity window, room/double-booking clashes and the
 * availability warning apply identically to a drag. Candidates load on demand
 * when the panel opens, ordered qualified-and-available first with the rest
 * behind "show all", labelled rather than hidden.
 *
 * A bottom SHEET below 768, a floating PANEL at 768+; both over a backdrop that
 * closes on click or Escape.
 */
export default function BlockPanel({
  facts, canManage, rosterHref, onAssigned, onUnassigned, onClose,
}: {
  facts: BlockFacts;
  canManage: boolean;
  rosterHref: string;
  onAssigned: (instructorId: string, instructorName: string) => void;
  onUnassigned: () => void;
  onClose: () => void;
}) {
  const assigned = facts.staffing === "assigned";
  const [candidates, setCandidates] = useState<AssignCandidate[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [who, setWho] = useState("");
  const [showAll, setShowAll] = useState(false);
  const [showUnassign, setShowUnassign] = useState(false);
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();

  // Escape closes, like the backdrop.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Candidates for any class the caller can staff — to fill an unstaffed one or
  // to swap the instructor on an assigned one.
  useEffect(() => {
    if (!canManage) return;
    let alive = true;
    assignCandidates(facts.id).then((r) => {
      if (!alive) return;
      if ("error" in r) setLoadError(r.error);
      else setCandidates(r.candidates);
    });
    return () => { alive = false; };
  }, [facts.id, canManage]);

  // The current instructor is not a target to change TO, so they are dropped
  // from the choices (and marked in the sentence above instead).
  const choices = (candidates ?? []).filter((c) => c.id !== facts.instructorId);
  const primary = choices.filter((c) => c.qualified && c.free);
  const rest = choices.filter((c) => !(c.qualified && c.free));
  // Nobody both qualified and free → open the full list so the dropdown is not empty.
  useEffect(() => {
    if (candidates && primary.length === 0 && rest.length > 0) setShowAll(true);
  }, [candidates, primary.length, rest.length]);

  const label = (c: AssignCandidate) => {
    const bits: string[] = [];
    if (!c.qualified) bits.push("not down to teach this");
    if (!c.free) bits.push("outside the hours they gave us");
    return bits.length ? ` — ${bits.join(", ")}` : "";
  };

  const runAssign = (action: typeof assignInstructor) => {
    if (!who) { setMsg({ ok: false, text: assigned ? "Pick who to change it to." : "Pick who is teaching it." }); return; }
    const fd = new FormData();
    fd.set("occurrence_id", facts.id);
    fd.set("instructor_id", who);
    setMsg(null);
    start(async () => {
      const r = await action(null, fd);
      if (r?.ok) {
        const name = choices.find((c) => c.id === who)?.display_name ?? "them";
        onAssigned(who, name);
      } else {
        setMsg({ ok: false, text: r?.message ?? "That could not be done." });
      }
    });
  };

  const doUnassign = () => {
    if (!reason.trim()) { setMsg({ ok: false, text: "Say why — the instructor being taken off gets this." }); return; }
    const fd = new FormData();
    fd.set("occurrence_id", facts.id);
    fd.set("reason", reason.trim());
    setMsg(null);
    start(async () => {
      const r = await openShift(null, fd);
      if (r?.ok) onUnassigned();
      else setMsg({ ok: false, text: r?.message ?? "That could not be done." });
    });
  };

  const doRepublish = () => {
    const fd = new FormData();
    fd.set("occurrence_id", facts.id);
    setMsg(null);
    start(async () => {
      const r = await republishShift(null, fd);
      if (r) setMsg({ ok: r.ok, text: r.message });
    });
  };

  // The shared instructor dropdown, used for both assign and change.
  const Picker = ({ placeholder }: { placeholder: string }) => (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <select value={who} onChange={(e) => setWho(e.target.value)}
                aria-label={placeholder}
                className="min-w-0 flex-1 rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink">
          <option value="">{placeholder}</option>
          {primary.length > 0 && (
            <optgroup label="Qualified and available">
              {primary.map((c) => <option key={c.id} value={c.id}>{c.display_name}</option>)}
            </optgroup>
          )}
          {showAll && rest.length > 0 && (
            <optgroup label="Everyone else">
              {rest.map((c) => <option key={c.id} value={c.id}>{c.display_name}{label(c)}</option>)}
            </optgroup>
          )}
        </select>
        <button onClick={() => runAssign(assigned ? reassignInstructor : assignInstructor)} disabled={pending}
                className="shrink-0 rounded-lg bg-lime px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-60">
          {pending ? "…" : assigned ? "Change" : "Assign"}
        </button>
      </div>
      {!showAll && rest.length > 0 && (
        <button type="button" onClick={() => setShowAll(true)}
                className="mt-1.5 text-[12px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Show all {choices.length}
        </button>
      )}
      {choices.length === 0 && (
        <p className="mt-1 text-[12px] leading-[18px] text-ink-2">
          No other instructor is working on this date.
        </p>
      )}
    </>
  );

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center md:items-center"
         role="dialog" aria-modal="true" aria-label={facts.title}>
      <button aria-label="Close" onClick={onClose}
              className="absolute inset-0 bg-black/30" />
      <div className="relative w-full max-h-[85vh] overflow-y-auto rounded-t-2xl border border-line
                      bg-surface p-4 shadow-xl md:w-[380px] md:rounded-2xl">
        {/* A grab handle on the sheet; hidden once it is a floating panel. */}
        <div className="mx-auto mb-2 h-1 w-9 rounded-full bg-line-2 md:hidden" aria-hidden />

        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="truncate text-[15px] font-semibold leading-5 text-ink">{facts.title}</p>
            <p className="num mt-0.5 text-[12.5px] leading-[18px] text-ink-2">{facts.when}</p>
          </div>
          <button onClick={onClose}
                  className="shrink-0 rounded-lg px-2 py-1 text-[12px] text-ink-3 hover:text-ink">
            Close
          </button>
        </div>

        <p className="mt-2 text-[13px] leading-[19px] text-ink-2">
          {assigned
            ? <>{facts.instructorName ?? "An instructor"} is teaching it.</>
            : <span className="font-medium text-ink">Nobody is teaching it.</span>}
          {" · "}
          <span className="num text-ink">{facts.bookedCount}/{facts.capacity}</span> booked
          {facts.waitlistCount > 0 && <> · <span className="num">+{facts.waitlistCount}</span> waiting</>}
          {facts.pendingApplications > 0 && (
            <> · <span className="num">{facts.pendingApplications}</span> applied</>
          )}
        </p>

        {canManage && (
          <div className="mt-3 border-t border-line pt-3">
            {msg && (
              <p className={`mb-2 text-[12.5px] leading-[18px] ${msg.ok ? "text-ink-2" : "text-coral-deep"}`}>
                {msg.text}
              </p>
            )}
            {loadError ? (
              <p className="text-[12.5px] leading-[18px] text-coral-deep">{loadError}</p>
            ) : candidates === null ? (
              <p className="text-[12.5px] leading-[18px] text-ink-3">Finding who could teach it…</p>
            ) : assigned ? (
              <>
                {/* CHANGE the instructor — same ordering as assigning; the
                    current one is dropped from the choices and named above. */}
                <Picker placeholder="Change to someone else…" />
                {/* UNASSIGN: open as a shift, per migration 114 — notifies the
                    instructor removed and re-solicits qualified ones. Needs the
                    reason they will be sent. */}
                <div className="mt-3 border-t border-line pt-3">
                  {!showUnassign ? (
                    <button type="button" onClick={() => { setShowUnassign(true); setMsg(null); }}
                            className="text-[12.5px] text-ink-2 underline underline-offset-4 hover:text-ink">
                      Unassign — open it as a shift
                    </button>
                  ) : (
                    <div>
                      <label className="block text-[12.5px] leading-[18px] text-ink-2">
                        {facts.instructorName ?? "The instructor"} will be taken off and told. Why?
                      </label>
                      <input value={reason} onChange={(e) => setReason(e.target.value)}
                             placeholder="e.g. off sick"
                             className="mt-1.5 w-full rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink" />
                      <div className="mt-2 flex items-center gap-2">
                        <button onClick={doUnassign} disabled={pending}
                                className="rounded-lg border border-coral bg-coral-tint px-3 py-1.5 text-[12.5px] font-medium text-ink disabled:opacity-60"
                                style={{ borderColor: "var(--coral)" }}>
                          {pending ? "…" : "Unassign"}
                        </button>
                        <button type="button" onClick={() => { setShowUnassign(false); setReason(""); }}
                                className="text-[12px] text-ink-3 hover:text-ink">Cancel</button>
                      </div>
                    </div>
                  )}
                </div>
              </>
            ) : (
              <>
                <Picker placeholder="Assign someone…" />
                <div className="mt-2.5">
                  <button onClick={doRepublish} disabled={pending}
                          className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[12.5px] text-ink-2 disabled:opacity-60">
                    Email qualified instructors again
                  </button>
                </div>
              </>
            )}
          </div>
        )}

        <div className="mt-3 border-t border-line pt-3">
          <a href={rosterHref} className="text-[13px] text-ink underline decoration-line-2 underline-offset-4 hover:decoration-ink">
            Open the full roster →
          </a>
        </div>
      </div>
    </div>
  );
}
