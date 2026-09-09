"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, Field, inputClass } from "@/components/ui";
import { saveCommitment, endCommitment, type AvailState } from "./actions";

export type Commitment = {
  id: string; starts_on: string; ends_on: string | null;
  min_per_week: number; target_per_week: number; shift_preference: string;
} | null;

/**
 * What was agreed about time.
 *
 * Decision 10 keeps compensation out of V1 and this stays the right side of
 * that line: there is no rate here and nothing that resolves to money owed.
 * What it buys is the Morning Brief being able to say "two weeks under nine" in
 * week three, rather than the studio noticing in month three when it is a
 * grievance instead of a conversation.
 */
export default function CommitmentForm({
  instructorId, commitment, canEdit, load, name,
}: {
  instructorId: string;
  commitment: Commitment;
  canEdit: boolean;
  load: { week_start: string; classes: number }[];
  name: string;
}) {
  const [saveState, save] = useFormState<AvailState, FormData>(saveCommitment, null);
  const [endState, end] = useFormState<AvailState, FormData>(endCommitment, null);
  const state = saveState ?? endState;
  const min = commitment?.min_per_week ?? 0;

  return (
    <div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {/* Actual against agreed, before the form. The number is the reason the
          record exists, so it goes above the thing that records it. */}
      {commitment && min > 0 && (
        <div className="mb-5 rounded-xl bg-paper p-4">
          <p className="mb-2.5 text-[12px] font-medium uppercase leading-4 tracking-[0.06em] text-ink-3">
            Classes taught, against a minimum of <span className="num">{min}</span>
          </p>
          {load.length === 0 ? (
            <p className="text-[13px] leading-[20px] text-ink-3">No complete weeks yet.</p>
          ) : (
            <ul className="flex flex-wrap gap-2">
              {load.map((w) => {
                const under = w.classes < min;
                return (
                  <li key={w.week_start}
                      className="rounded-lg px-3 py-2 text-center"
                      style={under
                        ? { background: "var(--coral-tint)" }
                        : { background: "var(--surface)" }}>
                    <span className="num block text-[17px] font-semibold leading-6 text-ink">
                      {w.classes}
                    </span>
                    <span className="num block text-[11px] leading-4 text-ink-2">
                      {w.week_start.slice(5)}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
          {load.some((w) => w.classes < min) && (
            <p className="mt-2.5 text-[12px] leading-[18px] text-ink-2">
              Weeks below the minimum are marked. Two in a row reaches the
              Morning Brief.
            </p>
          )}
          {/* Said plainly, because a number beside a scheduler invites the
              assumption that it drives one. It does not: classes are shared out
              by who has fewest that week, whatever is agreed here. */}
          <p className="mt-2.5 text-[12px] leading-[18px] text-ink-3">
            This is what you review them against. It does not decide who gets a
            class — the scheduler shares those out by who has fewest that week.
          </p>
        </div>
      )}

      {!canEdit ? (
        <p className="text-[13px] leading-[20px] text-ink-2">
          {commitment
            ? `${name} is down for a minimum of ${commitment.min_per_week} classes a week
               until ${commitment.ends_on ?? "further notice"}.`
            : "No commitment recorded."}{" "}
          Only owners and managers can change this.
        </p>
      ) : (
        <form action={save} className="space-y-4">
          <input type="hidden" name="instructor_id" value={instructorId} />
          {commitment && <input type="hidden" name="commitment_id" value={commitment.id} />}
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Starts">
              <input type="date" name="starts_on" required className={inputClass}
                     defaultValue={commitment?.starts_on ?? ""} />
            </Field>
            <Field label="Ends" hint="Blank for open-ended. Three months is the studio's usual floor.">
              <input type="date" name="ends_on" className={inputClass}
                     defaultValue={commitment?.ends_on ?? ""} />
            </Field>
            <Field label="Minimum classes a week" hint="What the brief measures against. 0 turns it off.">
              <input type="number" name="min_per_week" min={0} max={40} className={inputClass}
                     defaultValue={commitment?.min_per_week ?? 9} />
            </Field>
            <Field label="Target classes a week">
              <input type="number" name="target_per_week" min={0} max={40} className={inputClass}
                     defaultValue={commitment?.target_per_week ?? 12} />
            </Field>
            <Field label="Prefers">
              <select name="shift_preference" className={inputClass}
                      defaultValue={commitment?.shift_preference ?? "both"}>
                <option value="morning">Mornings</option>
                <option value="evening">Evenings</option>
                <option value="both">Either</option>
              </select>
            </Field>
          </div>
          <div className="flex gap-2">
            <SaveBtn label={commitment ? "Update the commitment" : "Record a commitment"} />
          </div>
        </form>
      )}

      {canEdit && commitment && (
        <form action={end} className="mt-3">
          <input type="hidden" name="instructor_id" value={instructorId} />
          <input type="hidden" name="commitment_id" value={commitment.id} />
          <EndBtn />
        </form>
      )}
    </div>
  );
}

function SaveBtn({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-lg bg-lime px-4 py-2 text-[14px] font-medium text-ink disabled:opacity-60">
      {pending ? "Saving…" : label}
    </button>
  );
}

function EndBtn() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="text-[13px] leading-[20px] text-ink-3 underline decoration-line-2 underline-offset-4 disabled:opacity-60">
      {pending ? "…" : "End this commitment"}
    </button>
  );
}
