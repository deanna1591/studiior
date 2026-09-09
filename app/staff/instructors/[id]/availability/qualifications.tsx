"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { saveQualifications, type AvailState } from "./actions";

/**
 * Which class types this instructor can teach.
 *
 * EMPTY MEANS NOTHING, NOT EVERYTHING, and the copy has to carry that — on the
 * day this ships every studio is unmapped, so the honest reading of a blank
 * list is "not set up yet", and a screen that says nothing would look broken
 * instead. The alternative reading ("no rows means anyone can teach anything")
 * makes the feature invisible until it is wrong.
 */
export default function Qualifications({
  instructorId, name, types, selected, canEdit,
}: {
  instructorId: string;
  name: string;
  types: { id: string; name: string }[];
  selected: string[];
  canEdit: boolean;
}) {
  const [state, action] = useFormState<AvailState, FormData>(saveQualifications, null);
  const [picked, setPicked] = useState<string[]>(selected);

  return (
    <form action={action}>
      <input type="hidden" name="instructor_id" value={instructorId} />
      <input type="hidden" name="class_type_ids" value={picked.join(",")} />
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {picked.length === 0 && (
        <p className="mb-3 rounded-xl px-3 py-2.5 text-[12.5px] leading-[19px]"
           style={{ background: "var(--amber-tint)", color: "var(--ink)" }}>
          Nothing ticked, which means {name} is not down to teach anything yet —
          not that they can teach everything. Until you tick something, the
          scheduler will leave their classes open rather than assign them.
        </p>
      )}

      {types.length === 0 ? (
        <p className="text-[13px] leading-[20px] text-ink-2">
          No class types yet. Add one first and it will appear here.
        </p>
      ) : (
        <ul className="flex flex-wrap gap-1.5">
          {types.map((t) => {
            const on = picked.includes(t.id);
            return (
              <li key={t.id}>
                <button
                  type="button" disabled={!canEdit}
                  aria-pressed={on}
                  onClick={() => setPicked((p) =>
                    p.includes(t.id) ? p.filter((x) => x !== t.id) : [...p, t.id])}
                  className="rounded-full px-3 py-1.5 text-[12.5px] font-medium disabled:opacity-60"
                  style={on
                    ? { background: "var(--lime-tint)", color: "var(--lime-text)",
                        boxShadow: "inset 0 0 0 1px var(--lime-text)" }
                    : { background: "var(--paper)", color: "var(--ink-2)" }}
                >
                  {t.name}
                </button>
              </li>
            );
          })}
        </ul>
      )}

      {canEdit && types.length > 0 && (
        <div className="mt-3 flex items-center gap-3">
          <Save />
          <span className="text-[12px] leading-4 text-ink-3">
            <span className="num">{picked.length}</span> of {types.length}
          </span>
        </div>
      )}
      {!canEdit && (
        <p className="mt-2 text-[12px] leading-4 text-ink-3">
          Only owners and managers can change this.
        </p>
      )}
    </form>
  );
}

function Save() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-lg bg-ink px-3.5 py-1.5 text-[13px] font-medium text-paper disabled:opacity-60">
      {pending ? "Saving…" : "Save"}
    </button>
  );
}
