"use client";

import { useFormState } from "react-dom";
import { PrimaryButton, CardAction, CardActionOutline, QuietButton } from "@/components/member/ui";
import {
  confirmMyWeek, askForCover, applyForShift, withdrawApplication, checkInMember,
  type InstructorState,
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

export function AskForCover({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(askForCover, null);
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

export function ApplyForShift({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(applyForShift, null);
  return (
    <form action={action} className="mt-2">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <CardAction>I can take it</CardAction>
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
