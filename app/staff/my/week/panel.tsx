"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { confirmWeek, askForCover, type MyState } from "../actions";

export type WeekClass = {
  occurrence_id: string;
  name: string;
  local: string;
  booked: number;
  confirmed: boolean;
  cover_status: string | null;
};

function Submit({ label, busy, className }: { label: string; busy: string; className?: string }) {
  const { pending } = useFormStatus();
  return (
    <button className={className ?? buttonClass} disabled={pending}>
      {pending ? busy : label}
    </button>
  );
}

/**
 * The week, as one decision.
 *
 * Eleven presses is how a studio ends up chasing two people about a button
 * rather than about a class, so the primary action is "confirm all of these"
 * with the list visible above it — the list is what makes one press honest.
 * Cover is per class, because that is genuinely per class, and it goes through
 * Decision 18's flow: staff always approve, and asking does not release you.
 */
export default function WeekPanel({
  instructorId, weekStart, weekLabel, classes,
}: {
  instructorId: string;
  weekStart: string;
  weekLabel: string;
  classes: WeekClass[];
}) {
  const [confirmState, doConfirm] = useFormState<MyState, FormData>(confirmWeek, null);
  const [coverState, doCover] = useFormState<MyState, FormData>(askForCover, null);
  const [openCover, setOpenCover] = useState<string | null>(null);

  const state = coverState ?? confirmState;
  const toAnswer = classes.filter((c) => !c.confirmed && !c.cover_status);

  return (
    <div className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <p className="mb-4 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
        {classes.length === 0
          ? `You have no classes in the week of ${weekLabel}.`
          : toAnswer.length === 0
          ? `All ${classes.length} of your classes for ${weekLabel} are answered. Nothing else to do.`
          : `You have ${classes.length} ${classes.length === 1 ? "class" : "classes"} in the week of ${weekLabel}. Confirm them in one go, or ask for cover on any you cannot make.`}
      </p>

      {classes.length > 0 && (
        <ul className="mb-5 divide-y divide-line rounded-xl border border-line bg-surface">
          {classes.map((c) => (
            <li key={c.occurrence_id} className="px-3.5 py-3">
              <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                <div className="min-w-0">
                  <span className="text-[14px] leading-5 text-ink">{c.name}</span>
                  <span className="num ml-2 text-[13px] leading-5 text-ink-2">{c.local}</span>
                  <span className="ml-2 text-[12px] leading-4 text-ink-3">
                    {c.booked} booked
                  </span>
                </div>
                {c.cover_status ? (
                  <span className="text-[12px] leading-4 text-ink-2">
                    Cover {c.cover_status === "pending" ? "requested — with the studio" : "arranged"}
                  </span>
                ) : c.confirmed ? (
                  <span className="text-[12px] leading-4 text-ink-3">Confirmed</span>
                ) : (
                  <button type="button" onClick={() => setOpenCover(
                        openCover === c.occurrence_id ? null : c.occurrence_id)}
                          className="text-[12.5px] leading-4 text-ink-2 underline underline-offset-4 hover:text-ink">
                    Ask for cover
                  </button>
                )}
              </div>

              {openCover === c.occurrence_id && (
                <form action={doCover} className="mt-2.5 flex flex-wrap items-end gap-2">
                  <input type="hidden" name="occurrence_id" value={c.occurrence_id} />
                  <label className="flex-1 text-[12.5px] leading-4 text-ink-2">
                    <span className="mb-1 block">Why, so the studio can judge it</span>
                    <input name="reason" placeholder="Dentist"
                           className="w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
                  </label>
                  <Submit label="Ask" busy="Asking…"
                          className="rounded-lg bg-ink px-3 py-1.5 text-[13px] font-medium text-paper" />
                </form>
              )}
            </li>
          ))}
        </ul>
      )}

      {toAnswer.length > 0 && (
        <form action={doConfirm}>
          <input type="hidden" name="instructor_id" value={instructorId} />
          <input type="hidden" name="week_start" value={weekStart} />
          <Submit
            label={`Confirm all ${toAnswer.length} ${toAnswer.length === 1 ? "class" : "classes"}`}
            busy="Confirming…"
          />
          <p className="mt-2 max-w-[58ch] text-[12px] leading-[18px] text-ink-3">
            Anything you have asked for cover on is left out of this — the studio
            is answering that one. Confirming late is fine and clears everything
            without fuss.
          </p>
        </form>
      )}
    </div>
  );
}
