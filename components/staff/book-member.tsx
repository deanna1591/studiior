"use client";

import { useEffect, useState, useTransition } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { useRouter } from "next/navigation";
import {
  bookingOptions, bookMemberAction, searchBookMembers, classPickerDays, feeTerms,
  type BookOptions, type BookOption, type MemberHit, type PickClass, type FeeTerms,
} from "@/app/staff/members/book-actions";

const fmtWhen = (iso: string) =>
  new Date(iso).toLocaleString(undefined,
    { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

const money = (c: number | null | undefined) =>
  c == null ? "" : (c / 100).toLocaleString(undefined, { maximumFractionDigits: 0 });

function toast(msg: string) {
  window.dispatchEvent(new CustomEvent("studiior:toast", { detail: msg }));
}

/** The core sheet: a member and a class are fixed; pick how to pay and book.
 *  optionsFn/bookFn are injected so the instructor portal can reuse it with its
 *  own actions (Decision 100 amendment b). */
export function Sheet({
  memberId, occurrenceId, onClose,
  optionsFn = bookingOptions, bookFn = bookMemberAction,
}: {
  memberId: string; occurrenceId: string; onClose: () => void;
  optionsFn?: typeof bookingOptions; bookFn?: typeof bookMemberAction;
}) {
  const router = useRouter();
  const [opts, setOpts] = useState<BookOptions>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [idx, setIdx] = useState(0);
  const [method, setMethod] = useState("cash");
  const [amount, setAmount] = useState<string>("");
  const [note, setNote] = useState("");
  // Decision 103 (k): off by default; Decision 100 (b) keeps a late add on.
  const [waive, setWaive] = useState(false);
  const [feeNote, setFeeNote] = useState("");
  const [terms, setTerms] = useState<FeeTerms>(null);
  const [freeOnFlex, setFreeOnFlex] = useState(false);  // Decision 30(e)
  const [result, setResult] = useState<string | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    let live = true;
    optionsFn(memberId, occurrenceId)
      .then((o) => { if (!live) return;
        if (!o || o.options.length === 0) { setLoadErr("Nothing can be booked for this class."); return; }
        setOpts(o); setIdx(o.preselect ?? 0);
        setWaive(!!o.late_add && o.method !== "instructor");
        const dp = o.options[o.preselect ?? 0];
        if (dp?.kind === "drop_in_paid" && dp.price_cents) setAmount(String(dp.price_cents / 100));
      })
      .catch(() => { if (live) setLoadErr("Could not load the options."); });
    feeTerms(occurrenceId, memberId).then((t) => { if (live) setTerms(t); }).catch(() => {});
    return () => { live = false; };
  }, [memberId, occurrenceId]);

  const chosen: BookOption | undefined = opts?.options[idx];
  const isFree = !!chosen && (chosen.kind === "free_first" || chosen.kind === "free_first_override");
  // Decision 103 (k): a free first class that owes the reservation fee shows the
  // fee and its deadline with a waive switch (staff only). An instructor late add
  // shows the line alone: the fee is due by the end of the studio day.
  const feeChoice = isFree && !!terms?.required;
  const isInstructor = opts?.method === "instructor";

  function submit() {
    if (!chosen) return;
    const source: BookOption = { ...chosen };
    if (chosen.kind === "drop_in_paid") {
      (source as Record<string, unknown>).method = method;
      (source as Record<string, unknown>).amount_cents = Math.round(Number(amount || "0") * 100);
    }
    if (feeChoice) {
      (source as Record<string, unknown>).fee_choice = !isInstructor && waive ? "waive" : "due";
      if (!isInstructor && waive && feeNote.trim()) (source as Record<string, unknown>).fee_note = feeNote.trim();
    }
    if (chosen.kind === "free_first" && freeOnFlex) {
      (source as Record<string, unknown>).allow_free_on_flex = true;
    }
    start(async () => {
      const r = await bookFn(memberId, occurrenceId, source, note.trim() || null);
      if ("error" in r) { setResult(r.error); return; }
      toast(`Booked ${opts?.member_first ?? "them"} with ${r.source}.`);
      onClose();
      router.refresh();
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true">
      <button className="absolute inset-0 bg-black/30" aria-label="Close" onClick={onClose} />
      <div className="relative w-full max-w-md rounded-t-2xl bg-surface p-5 shadow-xl sm:rounded-2xl">
        <h2 className="text-[17px] font-semibold text-ink">Book a class</h2>
        {loadErr ? (
          <p className="mt-3 text-[13px] text-coral-deep">{loadErr}</p>
        ) : !opts ? (
          <p className="mt-3 text-[13px] text-ink-3">Loading…</p>
        ) : opts.ended ? (
          <p className="mt-3 text-[13px] text-coral-deep">That class has already ended.</p>
        ) : (
          <>
            <p className="mt-1 text-[13px] text-ink-2">
              {opts.member_first} · {opts.class_name} · {fmtWhen(opts.starts_at)}
            </p>

            {opts.late_add && (
              <p className="mt-2 rounded-lg bg-paper px-3 py-2 text-[12px] text-ink-2">
                This class is in progress. {opts.member_first} will be added and checked in.
              </p>
            )}

            <label className="mt-4 block text-[13px] text-ink-2">
              <span className="mb-1 block">Pay with</span>
              <select
                className="w-full rounded-lg border border-line-2 bg-paper px-3 py-2 text-[14px] text-ink"
                value={idx}
                onChange={(e) => {
                  const i = Number(e.target.value); setIdx(i);
                  const o = opts.options[i];
                  if (o?.kind === "drop_in_paid" && o.price_cents) setAmount(String(o.price_cents / 100));
                }}
              >
                {opts.options.map((o, i) => (
                  <option key={i} value={i}>
                    {o.label}{o.kind === "drop_in_paid" && o.price_cents ? ` (${money(o.price_cents)})` : ""}
                  </option>
                ))}
              </select>
            </label>

            {chosen?.kind === "free_first" && (
              <label className="mt-3 flex items-start gap-2 text-[13px] text-ink-2">
                <input type="checkbox" className="mt-0.5" checked={freeOnFlex}
                       onChange={(e) => setFreeOnFlex(e.target.checked)} />
                <span>Allow this free class on a flex class
                  <span className="block text-[12px] text-ink-3">
                    Owners and managers only. Use it when the free first class is on a flex class your
                    studio normally keeps for core classes.
                  </span>
                </span>
              </label>
            )}

            {feeChoice && terms && (
              <div className="mt-3 rounded-lg bg-paper px-3 py-2.5" data-testid="fee-line">
                <p className="text-[13px] text-ink">
                  Reservation fee <span className="num font-semibold">{terms.fee_text}</span> due by {terms.deadline_label}
                </p>
                {!isInstructor ? (
                  <>
                    <label className="mt-2 flex items-start gap-2 text-[13px] text-ink-2">
                      <input type="checkbox" className="mt-0.5" checked={waive}
                             onChange={(e) => setWaive(e.target.checked)} />
                      <span>
                        <span className="font-medium text-ink">Waive the reservation fee</span>
                        <span className="mt-0.5 block text-[12px] text-ink-3">
                          {waive ? "No fee is asked for this booking." : "Off: the pay-to-keep email goes out now."}
                        </span>
                      </span>
                    </label>
                    {waive && (
                      <input className="mt-2 w-full rounded-lg border border-line-2 bg-surface px-3 py-2 text-[13px] text-ink"
                             placeholder="Why it is waived (optional)"
                             value={feeNote} onChange={(e) => setFeeNote(e.target.value)} />
                    )}
                  </>
                ) : (
                  <p className="mt-1 text-[12px] text-ink-3">The studio can waive it.</p>
                )}
              </div>
            )}

            {chosen?.kind === "drop_in_paid" && (
              <div className="mt-3 flex gap-2">
                <label className="flex-1 text-[13px] text-ink-2">
                  <span className="mb-1 block">Method</span>
                  <select className="w-full rounded-lg border border-line-2 bg-paper px-3 py-2 text-[14px] text-ink"
                          value={method} onChange={(e) => setMethod(e.target.value)}>
                    <option value="cash">Cash</option>
                    <option value="gcash">GCash</option>
                    <option value="card_terminal">Card terminal</option>
                  </select>
                </label>
                <label className="flex-1 text-[13px] text-ink-2">
                  <span className="mb-1 block">Amount</span>
                  <input className="w-full rounded-lg border border-line-2 bg-paper px-3 py-2 text-[14px] text-ink"
                         inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
                </label>
              </div>
            )}

            <label className="mt-3 block text-[13px] text-ink-2">
              <span className="mb-1 block">Note (optional)</span>
              <input className="w-full rounded-lg border border-line-2 bg-paper px-3 py-2 text-[14px] text-ink"
                     value={note} onChange={(e) => setNote(e.target.value)} />
            </label>

            {result && <p className="mt-3 text-[13px] text-coral-deep">{result}</p>}

            <div className="mt-4 flex gap-2">
              <button
                disabled={pending || !chosen}
                onClick={submit}
                className="flex-1 rounded-lg px-4 py-2.5 text-[14px] font-semibold disabled:opacity-60"
                style={accentSolid()}>
                {pending ? "Booking…" : `Book ${opts.member_first}`}
              </button>
              <button onClick={onClose}
                      className="rounded-lg border border-line-2 bg-surface px-4 py-2.5 text-[14px] text-ink">
                Cancel
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

/** Roster entry: search for a member, then book them into this class. */
export function BookMemberFromRoster({ occurrenceId }: { occurrenceId: string }) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState("");
  const [hits, setHits] = useState<MemberHit[]>([]);
  const [picked, setPicked] = useState<MemberHit | null>(null);

  useEffect(() => {
    if (!open || picked) return;
    const t = setTimeout(() => { searchBookMembers(term).then(setHits); }, 200);
    return () => clearTimeout(t);
  }, [term, open, picked]);

  return (
    <>
      <button onClick={() => setOpen(true)}
              className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink">
        Book a member
      </button>
      {open && !picked && (
        <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true">
          <button className="absolute inset-0 bg-black/30" aria-label="Close" onClick={() => { setOpen(false); setTerm(""); }} />
          <div className="relative w-full max-w-md rounded-t-2xl bg-surface p-5 shadow-xl sm:rounded-2xl">
            <h2 className="text-[17px] font-semibold text-ink">Book a member</h2>
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
        <Sheet memberId={picked.id} occurrenceId={occurrenceId}
               onClose={() => { setOpen(false); setPicked(null); setTerm(""); }} />
      )}
    </>
  );
}

/** Profile entry: pick a class in the next 14 days, then book this member. */
export function BookClassFromProfile({ memberId }: { memberId: string }) {
  const [open, setOpen] = useState(false);
  const [days, setDays] = useState<PickClass[] | null>(null);
  const [picked, setPicked] = useState<PickClass | null>(null);

  useEffect(() => {
    if (!open || picked) return;
    classPickerDays().then(setDays);
  }, [open, picked]);

  return (
    <>
      <button onClick={() => setOpen(true)}
              className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink">
        Book a class
      </button>
      {open && !picked && (
        <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true">
          <button className="absolute inset-0 bg-black/30" aria-label="Close" onClick={() => setOpen(false)} />
          <div className="relative w-full max-w-md rounded-t-2xl bg-surface p-5 shadow-xl sm:rounded-2xl">
            <h2 className="text-[17px] font-semibold text-ink">Book a class</h2>
            <p className="mt-1 text-[13px] text-ink-3">The next 14 days.</p>
            <ul className="mt-2 max-h-80 overflow-y-auto">
              {(days ?? []).map((c) => (
                <li key={c.id}>
                  <button onClick={() => setPicked(c)}
                          className="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[14px] text-ink hover:bg-paper">
                    <span>{c.name} <span className="text-ink-3">· {fmtWhen(c.starts_at)}</span></span>
                    <span className={c.full ? "text-ink-3" : "text-ink-2"}>
                      {c.full ? "Full" : `${c.spots_left} left`}
                    </span>
                  </button>
                </li>
              ))}
              {days && days.length === 0 && (
                <li className="px-3 py-2 text-[13px] text-ink-3">No classes in the next 14 days.</li>
              )}
              {!days && <li className="px-3 py-2 text-[13px] text-ink-3">Loading…</li>}
            </ul>
            <button onClick={() => setOpen(false)}
                    className="mt-2 rounded-lg border border-line-2 bg-surface px-4 py-2 text-[13px] text-ink">Cancel</button>
          </div>
        </div>
      )}
      {open && picked && (
        <Sheet memberId={memberId} occurrenceId={picked.id}
               onClose={() => { setOpen(false); setPicked(null); }} />
      )}
    </>
  );
}
