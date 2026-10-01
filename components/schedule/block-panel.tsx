"use client";

import { useEffect, useState, useTransition } from "react";
import { republishShift, openShift } from "@/app/staff/roster/actions";
import { assignCandidates } from "@/app/staff/schedule/actions";
import { assignOccurrencesForPeriod } from "@/app/staff/schedule/actions";
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
 * The staffing control, inline over the calendar block (Decision 42a). Assign or
 * unassign an instructor for a SCOPE — just this class, every week this month,
 * or until a date — without leaving the week. Every occurrence is written
 * through the single-occurrence path (assign_occurrences_for_period →
 * reassign_occurrence / move_occurrence), so Decision 38's confirmation request,
 * the double-booking constraints and the audit all apply; a clash is skipped and
 * named. The series template is never touched. "Unassigned" at the top of the
 * dropdown opens the class as a shift (Decision 17).
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
  const [who, setWho] = useState("");                    // "" nothing, "__open" unassign, else instructor id
  const [scope, setScope] = useState<"one" | "month" | "until">("one");
  const [until, setUntil] = useState("");
  const [confirmed, setConfirmed] = useState(true);      // Decision 38 bypass, ticked by default
  const [showAll, setShowAll] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

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

  // The current instructor is not a target to change TO; dropped from the
  // choices and named above instead.
  const choices = (candidates ?? []).filter((c) => c.id !== facts.instructorId);
  const primary = choices.filter((c) => c.qualified && c.free);
  const rest = choices.filter((c) => !(c.qualified && c.free));
  useEffect(() => {
    if (candidates && primary.length === 0 && rest.length > 0) setShowAll(true);
  }, [candidates, primary.length, rest.length]);

  const label = (c: AssignCandidate) => {
    const bits: string[] = [];
    if (!c.qualified) bits.push("not down to teach this");
    if (!c.free) bits.push("outside the hours they gave us");
    return bits.length ? ` — ${bits.join(", ")}` : "";
  };

  const unassigning = who === "__open";
  const submit = () => {
    if (!who) { setMsg({ ok: false, text: "Pick an instructor, or Unassigned." }); return; }
    if (scope === "until" && !until) { setMsg({ ok: false, text: "Pick a date to assign until." }); return; }
    const fd = new FormData();
    fd.set("occurrence_id", facts.id);
    fd.set("instructor_id", unassigning ? "" : who);
    fd.set("scope", scope);
    if (scope === "until") fd.set("until", until);
    if (confirmed && !unassigning) fd.set("confirmed", "on");
    setMsg(null);
    start(async () => {
      const r = await assignOccurrencesForPeriod(null, fd);
      if (r?.ok) {
        setMsg({ ok: true, text: r.message });
        if (unassigning) onUnassigned();
        else {
          const name = choices.find((c) => c.id === who)?.display_name ?? "them";
          onAssigned(who, name);
        }
      } else {
        setMsg({ ok: false, text: r?.message ?? "That could not be done." });
      }
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

  const ScopeRadio = ({ value, children }: { value: "one" | "month" | "until"; children: React.ReactNode }) => (
    <label className="flex items-center gap-1.5 text-[12.5px] text-ink">
      <input type="radio" name="scope" checked={scope === value} onChange={() => setScope(value)} />
      {children}
    </label>
  );

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center md:items-center"
         role="dialog" aria-modal="true" aria-label={facts.title}>
      <button aria-label="Close" onClick={onClose} className="absolute inset-0 bg-black/30" />
      <div className="relative w-full max-h-[85vh] overflow-y-auto rounded-t-2xl border border-line
                      bg-surface p-4 shadow-xl md:w-[400px] md:rounded-2xl">
        <div className="mx-auto mb-2 h-1 w-9 rounded-full bg-line-2 md:hidden" aria-hidden />

        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="truncate text-[15px] font-semibold leading-5 text-ink">{facts.title}</p>
            <p className="num mt-0.5 text-[12.5px] leading-[18px] text-ink-2">{facts.when}</p>
          </div>
          <button onClick={onClose} className="shrink-0 rounded-lg px-2 py-1 text-[12px] text-ink-3 hover:text-ink">
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
          {facts.pendingApplications > 0 && <> · <span className="num">{facts.pendingApplications}</span> applied</>}
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
            ) : (
              <>
                <select value={who} onChange={(e) => setWho(e.target.value)} aria-label="Assign to"
                        className="w-full rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink">
                  <option value="">{assigned ? "Change to…" : "Assign someone…"}</option>
                  <option value="__open">Unassigned — open it as a shift</option>
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
                {!showAll && rest.length > 0 && (
                  <button type="button" onClick={() => setShowAll(true)}
                          className="mt-1.5 text-[12px] text-ink-3 underline underline-offset-4 hover:text-ink">
                    Show all {choices.length}
                  </button>
                )}

                {/* Scope — just this class, the month, or until a date. */}
                <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5">
                  <ScopeRadio value="one">Just this class</ScopeRadio>
                  <ScopeRadio value="month">Every week this month</ScopeRadio>
                  <ScopeRadio value="until">Until…</ScopeRadio>
                  {scope === "until" && (
                    <input type="date" value={until} onChange={(e) => setUntil(e.target.value)}
                           aria-label="Assign until"
                           className="num rounded-lg border border-line-2 bg-paper px-2 py-1 text-[12.5px] text-ink" />
                  )}
                </div>

                {/* Decision 38 bypass — ticked by default, hidden when unassigning. */}
                {!unassigning && (
                  <label className="mt-2.5 flex items-start gap-2 text-[12.5px] leading-[18px] text-ink-2">
                    <input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} className="mt-0.5" />
                    <span>Already confirmed with the instructor — don&rsquo;t ask them</span>
                  </label>
                )}

                <div className="mt-3 flex items-center gap-2">
                  <button onClick={submit} disabled={pending}
                          className="rounded-lg bg-lime px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-60">
                    {pending ? "…" : unassigning ? "Unassign" : "Assign"}
                  </button>
                  {!assigned && (
                    <button onClick={doRepublish} disabled={pending}
                            className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[12.5px] text-ink-2 disabled:opacity-60">
                      Email qualified instructors again
                    </button>
                  )}
                </div>

                {/* The deliberate "take off + tell them why" path (Decision 17),
                    for a single class — kept beside the scope control. */}
                {assigned && <OpenAsShift occurrenceId={facts.id} instructorName={facts.instructorName}
                                          onDone={onUnassigned} onMsg={setMsg} pending={pending} start={start} />}
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

function OpenAsShift({ occurrenceId, instructorName, onDone, onMsg, pending, start }: {
  occurrenceId: string; instructorName: string | null;
  onDone: () => void; onMsg: (m: { ok: boolean; text: string }) => void;
  pending: boolean; start: (cb: () => void) => void;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const go = () => {
    if (!reason.trim()) { onMsg({ ok: false, text: "Say why — the instructor being taken off gets this." }); return; }
    const fd = new FormData();
    fd.set("occurrence_id", occurrenceId);
    fd.set("reason", reason.trim());
    start(async () => {
      const r = await openShift(null, fd);
      if (r?.ok) onDone(); else onMsg({ ok: false, text: r?.message ?? "That could not be done." });
    });
  };
  return (
    <div className="mt-3 border-t border-line pt-3">
      {!open ? (
        <button type="button" onClick={() => setOpen(true)}
                className="text-[12px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Or open it as a shift and tell {instructorName ?? "them"} why
        </button>
      ) : (
        <div>
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. off sick"
                 className="w-full rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink" />
          <div className="mt-2 flex items-center gap-2">
            <button onClick={go} disabled={pending}
                    className="rounded-lg border bg-coral-tint px-3 py-1.5 text-[12.5px] font-medium text-ink disabled:opacity-60"
                    style={{ borderColor: "var(--coral)" }}>
              {pending ? "…" : "Open as a shift"}
            </button>
            <button type="button" onClick={() => { setOpen(false); setReason(""); }}
                    className="text-[12px] text-ink-3 hover:text-ink">Cancel</button>
          </div>
        </div>
      )}
    </div>
  );
}
