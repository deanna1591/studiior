"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import {
  archiveSeries, restoreSeries, endSeries, deleteSeries, type LifecycleState,
} from "./lifecycle-actions";

function Btn({ label, tone = "quiet" }: { label: string; tone?: "quiet" | "strong" | "danger" }) {
  const { pending } = useFormStatus();
  const style =
    tone === "danger" ? { borderColor: "var(--coral)", color: "var(--coral-deep)" }
    : tone === "strong" ? { borderColor: "var(--ink)", color: "var(--ink)" }
    : { borderColor: "var(--line-2)", color: "var(--ink-2)" };
  return (
    <button disabled={pending}
            className="m-tap shrink-0 rounded-lg border px-3 py-1.5 text-[13px] font-medium disabled:opacity-60"
            style={style}>
      {pending ? "…" : label}
    </button>
  );
}

/**
 * Stopping a series, in the order a studio actually wants them.
 *
 * ARCHIVE IS THE OBVIOUS ONE. It is what somebody means nine times in ten: stop
 * making new classes, get it off the working list, keep every class it has
 * already made and everybody's bookings with them.
 *
 * ENDING is for a series that should run to a date and then stop, and it stays
 * visible while that date is still recent.
 *
 * DELETING is for a mistake made five minutes ago. The database refuses it the
 * moment anything has run or anybody has booked — `class_occurrences.series_id`
 * is ON DELETE CASCADE, so a delete that got through would take the classes,
 * their bookings and their check-ins with it, silently. That was reproduced
 * before migration 078 was written: DELETE 1, no error, 35 classes, 84 bookings
 * and 63 check-ins gone.
 */
export default function SeriesLifecycle({
  id, name, archived, endsOn, today,
}: {
  id: string; name: string; archived: boolean;
  endsOn: string | null; today: string;
}) {
  const [archState, archive] = useFormState<LifecycleState, FormData>(archiveSeries, null);
  const [restState, restore] = useFormState<LifecycleState, FormData>(restoreSeries, null);
  const [endState, end] = useFormState<LifecycleState, FormData>(endSeries, null);
  const [delState, remove] = useFormState<LifecycleState, FormData>(deleteSeries, null);

  const state = archState ?? restState ?? endState ?? delState;
  const confirmArchive = archState && !archState.ok && "confirm" in archState;
  const confirmEnd = endState && !endState.ok && "confirm" in endState;
  const confirmDelete = delState && !delState.ok && "confirm" in delState;
  const blocked = endState && !endState.ok && "blocked" in endState ? endState.blocked : null;

  if (archived) {
    return (
      <section className="mt-8 border-t border-line pt-5">
        {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
        <div className="flex flex-wrap items-center gap-3">
          <p className="m-sub flex-1 text-ink-2">
            <span className="text-ink">{name}</span> is archived. It is making no new
            classes and is off the working list. Everything it already taught is
            untouched, and any class somebody was booked on is still running.
          </p>
          <form action={restore}>
            <input type="hidden" name="id" value={id} />
            <Btn label="Restore" tone="strong" />
          </form>
        </div>
      </section>
    );
  }

  return (
    <section className="mt-8 border-t border-line pt-5">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {blocked && (
        <ul className="mb-4 space-y-1 rounded border border-coral bg-coral-tint px-3.5 py-3">
          {blocked.map((b) => (
            <li key={b.local} className="text-[13px] leading-5 text-ink">
              <span className="num">{b.local}</span>
              <span className="text-ink-2"> — {b.booked} booked</span>
            </li>
          ))}
        </ul>
      )}

      {/* 1. The normal action. */}
      <div className="flex flex-wrap items-center gap-3 rounded border border-line bg-surface px-3.5 py-3">
        <p className="m-sub flex-1 text-ink-2">
          <span className="text-ink">Archive it.</span> Stops it making new classes and
          takes it off your list. Every class it has already taught keeps its bookings
          and its history, and any future class somebody is booked on is kept and still
          runs. You can restore it.
        </p>
        <form action={archive}>
          <input type="hidden" name="id" value={id} />
          {confirmArchive && <input type="hidden" name="confirm" value="1" />}
          <Btn label={confirmArchive ? "Yes, archive it" : "Archive"} tone="strong" />
        </form>
      </div>

      {/* 2. Run to a date and stop. */}
      <form action={end} className="mt-4 flex flex-wrap items-end gap-3 px-3.5">
        <input type="hidden" name="id" value={id} />
        {confirmEnd && <input type="hidden" name="confirm" value="1" />}
        <div>
          {/* NOT named ends_on: the edit form on this same page already posts a
              hidden ends_on, and two inputs of one name on one screen is a trap
              for anything reading the DOM — it cost a round of testing here. */}
          <label htmlFor="end_on_date" className="m-micro block text-ink-3">Or end it on</label>
          <input id="end_on_date" name="end_on_date" type="date" defaultValue={endsOn ?? today}
                 className="mt-1 rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
        </div>
        <Btn label={confirmEnd ? "Yes, end it" : "End it"} />
        <p className="m-micro w-full text-ink-3">
          The series stops on that day and stays on your list while it is still
          recent. Classes after it are cancelled — and if anybody is booked on one,
          this is refused and says who.
        </p>
      </form>

      {/* 3. The mistake made five minutes ago. */}
      <form action={remove} className="mt-6 border-t border-line pt-4">
        <input type="hidden" name="id" value={id} />
        {confirmDelete && <input type="hidden" name="confirm" value="1" />}
        <Btn label={confirmDelete ? "Yes, delete it permanently" : "Delete this series"}
             tone="danger" />
        <p className="m-micro mt-2 max-w-[58ch] text-ink-3">
          Only while nothing has happened yet. Once a class has run, or anybody has
          booked one, deleting would take those classes and their bookings with it —
          so it is refused, and it tells you what is in the way.
        </p>
      </form>
    </section>
  );
}
