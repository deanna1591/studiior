"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { approveCover, declineCover, requestCover, withdrawCover, type CoverState } from "./actions";

function Btn({ label, tone = "quiet" }: { label: string; tone?: "primary" | "quiet" }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className={`shrink-0 rounded-lg px-3 py-1.5 text-[13px] font-medium disabled:opacity-60 ${
        tone === "primary" ? "bg-lime text-ink" : "border border-line-2 bg-surface text-ink-2"}`}>
      {pending ? "…" : label}
    </button>
  );
}

/**
 * The instructor's side: ask, and be able to take it back.
 *
 * The reason field is optional and the copy says what happens next, because the
 * one thing an instructor must not walk away believing is that asking released
 * them. Until staff answer, they are teaching it.
 */
export function RequestCoverForm({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<CoverState, FormData>(requestCover, null);
  const [open, setOpen] = useState(false);
  return (
    <div className="shrink-0 text-right">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      {!open && !state?.ok ? (
        <button onClick={() => setOpen(true)}
                className="shrink-0 rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink-2">
          Ask for cover
        </button>
      ) : !state?.ok ? (
        <form action={action} className="flex flex-wrap items-center justify-end gap-2">
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <input name="reason" placeholder="Why, if you want to say"
                 className="w-[220px] rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink" />
          <Btn label="Ask the studio" tone="primary" />
        </form>
      ) : null}
    </div>
  );
}

export function WithdrawCoverForm({ requestId }: { requestId: string }) {
  const [state, action] = useFormState<CoverState, FormData>(withdrawCover, null);
  return (
    <form action={action} className="shrink-0 text-right">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <input type="hidden" name="request_id" value={requestId} />
      <Btn label="Never mind, I can do it" />
    </form>
  );
}

/**
 * The studio's side.
 *
 * Two ways to say yes and they are genuinely different decisions, so they are
 * two controls rather than a mode toggle: naming a replacement settles it now;
 * opening it up asks the room. Both go through the same call.
 */
export function DecideCoverForm({
  requestId, instructors, bookedCount,
}: {
  requestId: string;
  instructors: { id: string; display_name: string; free: boolean }[];
  bookedCount: number;
}) {
  const [approveState, approve] = useFormState<CoverState, FormData>(approveCover, null);
  const [declineState, decline] = useFormState<CoverState, FormData>(declineCover, null);
  const state = approveState ?? declineState;
  const [who, setWho] = useState("");

  return (
    <div className="mt-3 border-t border-line pt-3">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="flex flex-wrap items-center gap-2">
        <form action={approve} className="flex flex-wrap items-center gap-2">
          <input type="hidden" name="request_id" value={requestId} />
          <input type="hidden" name="mode" value="assign" />
          <select name="instructor_id" value={who} onChange={(e) => setWho(e.target.value)}
                  aria-label="Who is covering it"
                  className="rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink">
            <option value="">Assign someone…</option>
            {instructors.map((x) => (
              <option key={x.id} value={x.id}>
                {x.display_name}
                {/* Availability is context, never a filter — Decision 9. The
                    person deciding sees it at the moment they decide. */}
                {x.free ? "" : " (outside their availability)"}
              </option>
            ))}
          </select>
          <Btn label="Assign" tone="primary" />
        </form>

        <form action={approve}>
          <input type="hidden" name="request_id" value={requestId} />
          <input type="hidden" name="mode" value="open" />
          <Btn label="Open it up instead" />
        </form>

        <form action={decline} className="flex flex-wrap items-center gap-2">
          <input type="hidden" name="request_id" value={requestId} />
          <input name="reason" placeholder="Why not, if you want to say"
                 className="w-[200px] rounded-lg border border-line-2 bg-paper px-2.5 py-1.5 text-[13px] text-ink" />
          <Btn label="They'll have to teach it" />
        </form>
      </div>
      {bookedCount > 0 && (
        <p className="mt-2 text-[12px] leading-[18px] text-ink-2">
          Assigning someone emails the{" "}
          <span className="num">{bookedCount}</span> booked member
          {bookedCount === 1 ? "" : "s"}. Opening it up does not — members are
          not told a class is unstaffed.
        </p>
      )}
    </div>
  );
}
