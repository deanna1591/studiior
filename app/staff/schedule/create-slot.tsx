"use client";

import { useEffect, useRef } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { createOnSlot, type CreateState } from "./create-actions";

function Add() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="m-tap rounded-lg px-3.5 py-2 text-[13px] font-medium disabled:opacity-60"
            style={{ background: "var(--ink)", color: "var(--paper)" }}>
      {pending ? "Adding…" : "Add class"}
    </button>
  );
}

export type SlotDraft = {
  /** Real instants, ISO — converted from wall time before it gets here. */
  startsAt: string;
  endsAt: string;
  /** Null means the Unassigned column: an open shift, not a missing value. */
  instructorId: string | null;
  instructorName: string | null;
  /** Studio-local, formatted on the server side of the boundary. */
  when: string;
  minutes: number;
};

/**
 * The form a slot-click opens.
 *
 * It asks for what the slot cannot supply and nothing else: the class type, and
 * duration and capacity only if they differ from that type's defaults. The date,
 * the time and the instructor come from where the click landed.
 */
export default function CreateOnSlot({
  draft, classTypes, rooms, onDone, onCancel,
}: {
  draft: SlotDraft;
  classTypes: { id: string; name: string; duration_minutes: number; default_capacity: number }[];
  rooms: { id: string; name: string; capacity: number }[];
  onDone: () => void;
  onCancel: () => void;
}) {
  const [state, action] = useFormState<CreateState, FormData>(createOnSlot, null);
  const done = useRef(false);
  useEffect(() => {
    if (state && "ok" in state && state.ok && !done.current) {
      done.current = true;
      // A beat, so the studio reads the warning before the panel closes.
      const t = setTimeout(onDone, state.warnings.length ? 2200 : 700);
      return () => clearTimeout(t);
    }
  }, [state, onDone]);

  const needRoom = state && !state.ok && "needRoom" in state;
  const blocked = state && !state.ok && "blockedBy" in state ? state.blockedBy : undefined;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/20 p-4 sm:items-center"
         role="dialog" aria-modal="true" aria-label="Add a class">
      <form action={action}
            className="w-full max-w-lg rounded-xl border border-line bg-surface p-4 shadow-lg">
        <input type="hidden" name="starts_at" value={draft.startsAt} />
        <input type="hidden" name="ends_at" value={draft.endsAt} />
        <input type="hidden" name="instructor_id" value={draft.instructorId ?? ""} />

        <p className="text-[15px] font-medium leading-5 text-ink">{draft.when}</p>
        <p className="mt-0.5 text-[12.5px] leading-[18px] text-ink-3">
          <span className="num">{draft.minutes}</span> minutes ·{" "}
          {draft.instructorName
            ? <>with <span className="text-ink-2">{draft.instructorName}</span></>
            : <>nobody assigned — this will be an open shift instructors can apply for</>}
          . A one-off, not a repeating class.
        </p>

        {state && !state.ok && (
          <div className="mt-3 rounded border px-3 py-2 text-[13px] leading-[19px] text-ink"
               style={{ borderColor: "var(--coral)", background: "var(--coral-tint)" }} role="alert">
            {state.message}
            {blocked?.name && (
              <>
                {" "}
                <a href={blocked.occurrenceId ? `/roster/${blocked.occurrenceId}` : "#"}
                   className="font-medium underline underline-offset-4">
                  {blocked.who ? `${blocked.who} is teaching ` : ""}{blocked.name}
                  {blocked.at ? ` at ${blocked.at}` : ""}
                  {blocked.room ? ` in ${blocked.room}` : ""}
                </a>.
              </>
            )}
          </div>
        )}
        {state && state.ok && (
          <div className="mt-3 rounded border px-3 py-2 text-[13px] leading-[19px] text-ink"
               style={{ borderColor: "var(--line-2)", background: "var(--paper)" }} role="status">
            {state.message}
          </div>
        )}

        <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">What kind of class</span>
          <select name="class_type_id" required
                  className="w-full rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink">
            <option value="">Choose…</option>
            {classTypes.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name} — {c.duration_minutes} min, holds {c.default_capacity}
              </option>
            ))}
          </select>
        </label>

        {/* Only asked when the studio has more than one room. With one, the
            database uses it; with none, the class has no room and the exclusion
            constraint cannot protect it — which is why "no room" is never a
            silent default. */}
        {(needRoom || rooms.length > 1) && (
          <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
            <span className="mb-1 block">Which room</span>
            <select name="room_id" required
                    className="w-full rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink">
              <option value="">Choose…</option>
              {(needRoom && "rooms" in state ? state.rooms : rooms).map((r) => (
                <option key={r.id} value={r.id}>{r.name} — holds {r.capacity}</option>
              ))}
            </select>
          </label>
        )}
        {rooms.length === 1 && <input type="hidden" name="room_id" value={rooms[0].id} />}

        <label className="mt-3 block text-[13px] leading-[20px] text-ink-2">
          <span className="mb-1 block">
            Capacity <span className="text-ink-3">— leave blank for the class type&rsquo;s own</span>
          </span>
          <input name="capacity" type="number" min={1} max={200}
                 className="w-28 rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
        </label>

        <div className="mt-4 flex items-center gap-3">
          <Add />
          <button type="button" onClick={onCancel}
                  className="m-tap rounded-lg border px-3 py-1.5 text-[13px] font-medium"
                  style={{ borderColor: "var(--line-2)", color: "var(--ink-2)" }}>
            Cancel
          </button>
          <span className="m-micro text-ink-3">Repeating classes live in Recurring.</span>
        </div>
      </form>
    </div>
  );
}
