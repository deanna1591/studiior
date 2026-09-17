"use client";

import { useFormState } from "react-dom";
import { PrimaryButton, CardAction, CardActionOutline, QuietButton } from "@/components/member/ui";
import {
  confirmMyWeek, confirmMyMonth, askForCover, applyForShift, claimClass, acceptCover, withdrawApplication, checkInMember,
  type InstructorState, type ClaimState,
} from "./actions";

function Result({ state }: { state: InstructorState }) {
  if (!state) return null;
  const bad = "error" in state;
  return (
    <p className={`mt-2 text-[12px] leading-[17px] ${bad ? "text-ink" : "text-ink-2"}`}
       role={bad ? "alert" : "status"}
       style={bad ? { borderLeft: "3px solid var(--coral)", paddingLeft: 8 } : undefined}>
      {bad ? state.error : state.ok}
    </p>
  );
}

export function ConfirmWeek({
  instructorId, count, weekStart,
}: { instructorId: string; count: number; weekStart: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(confirmMyWeek, null);
  return (
    <form action={action} className="m-card mb-4 px-4 py-3.5">
      <p className="text-[15px] leading-[22px] text-ink">
        <span className="num font-semibold">{count}</span>{" "}
        {count === 1 ? "class needs" : "classes need"} confirming this week.
      </p>
      <p className="m-sub mt-0.5 text-ink-3">
        One press for the lot. Anything you have asked cover for is left alone.
      </p>
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="week_start" value={weekStart} />
      <div className="mt-3"><PrimaryButton>{`Confirm all ${count}`}</PrimaryButton></div>
      <Result state={state} />
    </form>
  );
}

/**
 * Decision 25: the month is the agreement. Flagging a class is AskForCover
 * below, on the class itself; this confirms everything else in one press.
 */
export function ConfirmMonth({
  instructorId, month, label, count, flagged,
}: { instructorId: string; month: string; label: string; count: number; flagged: number }) {
  const [state, action] = useFormState<InstructorState, FormData>(confirmMyMonth, null);
  return (
    <form action={action} className="m-card mb-4 px-4 py-3.5">
      <p className="text-[15px] leading-[22px] text-ink">
        <span className="num font-semibold">{count}</span>{" "}
        {count === 1 ? "class" : "classes"} in {label}. Can you do them?
      </p>
      <p className="m-sub mt-0.5 text-ink-3">
        One press for the month. Flag any you cannot do below, and confirm the rest.
        {flagged > 0 && <> {flagged} already flagged for cover.</>}
      </p>
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="month" value={month} />
      <div className="mt-3"><PrimaryButton>{`Confirm ${label}`}</PrimaryButton></div>
      <Result state={state} />
    </form>
  );
}

export function AskForCover({ occurrenceId, compact = false }: { occurrenceId: string; compact?: boolean }) {
  const [state, action] = useFormState<InstructorState, FormData>(askForCover, null);
  // On the month roster there are twenty of these in a column; the form opens
  // on demand there. A native <details> — no state to lose.
  if (compact) {
    return (
      <details className="mt-2">
        <summary className="m-tap inline-flex cursor-pointer items-center text-[13px] font-medium text-[color:var(--accent-text)] underline underline-offset-4">
          I can&rsquo;t do this one
        </summary>
        <form action={action} className="mt-2">
          <input type="hidden" name="occurrence_id" value={occurrenceId} />
          <input name="reason" required aria-label="Why"
                 placeholder="Why — the studio decides from this"
                 className="m-tap w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink placeholder:text-ink-3" />
          <div className="mt-2"><CardActionOutline>Ask the studio for cover</CardActionOutline></div>
          <Result state={state} />
        </form>
      </details>
    );
  }
  return (
    <form action={action} className="mt-3">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <label className="m-sub block text-ink-2" htmlFor="reason">
        Ask for cover
      </label>
      <input id="reason" name="reason" required
             placeholder="Why — the studio decides from this"
             className="m-tap mt-1 w-full rounded-xl border border-[color:var(--line-2)] bg-[color:var(--surface)] px-3 text-[15px] text-ink placeholder:text-ink-3" />
      <div className="mt-2"><CardActionOutline>Ask the studio</CardActionOutline></div>
      <p className="m-sub mt-1.5 text-ink-3">
        You stay down to teach it until somebody approves. Nothing is released
        automatically, however close it is.
      </p>
      <Result state={state} />
    </form>
  );
}

/**
 * Committing to an open shift flips the class to pending_approval, so it drops
 * out of the open list. Rather than let it vanish behind a badge, the action
 * does NOT revalidate this list — the row stays put and confirms in place what
 * just happened, naming the class and where it has gone.
 */
export function ApplyForShift({
  occurrenceId, name, when, studioName,
}: { occurrenceId: string; name: string; when: string; studioName: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(applyForShift, null);
  if (state && "ok" in state) {
    return (
      <div className="mt-2 rounded-xl px-3 py-2.5" style={{ background: "var(--accent-chip)" }} role="status">
        <p className="text-[13px] leading-[18px] text-ink">
          <span className="font-semibold">Asked to take {name}</span>, {when}. {studioName} will confirm.
        </p>
        <p className="mt-0.5 text-[12px] leading-[17px] text-ink-2">
          It&rsquo;s on your schedule now, marked pending.
        </p>
      </div>
    );
  }
  return (
    <form action={action} className="mt-2">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <CardAction>Commit</CardAction>
      {state && "error" in state && <Result state={state} />}
    </form>
  );
}

/**
 * Claiming (149). Claim it → staff approve. Over the core cap it does not
 * refuse: the button becomes "Ask anyway" with the numbers, and the second
 * press records the over-cap flag for the studio.
 */
export function ClaimClass({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<ClaimState, FormData>(claimClass, null);
  const overCap = state && "overCap" in state ? state.overCap : null;
  return (
    <form action={action} className="mt-2">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {overCap ? (
        <>
          <p className="text-[12px] leading-[17px] text-ink"
             style={{ borderLeft: "3px solid var(--accent)", paddingLeft: 8 }}>
            That is your <span className="num">{overCap.cap}</span>{overCap.cap === 1 ? "" : ""} core
            {" "}{overCap.cap === 1 ? "class" : "classes"} for the week already. You can still put your name forward — the studio decides.
          </p>
          <input type="hidden" name="over_cap_ack" value="1" />
          <div className="mt-2"><CardActionOutline>Ask anyway</CardActionOutline></div>
        </>
      ) : (
        <CardAction>Claim it</CardAction>
      )}
      {state && ("error" in state || "ok" in state) && <Result state={state as InstructorState} />}
    </form>
  );
}

/** Auto-accept cover (156): take an urgent cover, no approval round. */
export function AcceptCover({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(acceptCover, null);
  return (
    <form action={action} className="mt-2">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <CardAction>Take it</CardAction>
      <Result state={state} />
    </form>
  );
}

export function WithdrawApplication({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(withdrawApplication, null);
  return (
    <form action={action} className="mt-2">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <CardActionOutline>Withdraw</CardActionOutline>
      <Result state={state} />
    </form>
  );
}

export function CheckIn({
  studioId, occurrenceId, bookingId, memberId,
}: { studioId: string; occurrenceId: string; bookingId: string; memberId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(checkInMember, null);
  return (
    <form action={action}>
      <input type="hidden" name="studio_id" value={studioId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="member_id" value={memberId} />
      <QuietButton>Check in</QuietButton>
      {state && "error" in state && (
        <span className="m-sub block text-ink">{state.error}</span>
      )}
    </form>
  );
}
