"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { saveClassTypeInstructors, type TypeState } from "./actions";

/**
 * The same mapping from the class type's side.
 *
 * Both directions exist because both are the natural way in: a studio adding an
 * instructor ticks what they teach, and a studio adding a class type ticks who
 * can teach it. One table, two screens, one write path each.
 */
export default function TypeInstructors({
  classTypeId, typeName, instructors, selected, canEdit,
}: {
  classTypeId: string;
  typeName: string;
  instructors: { id: string; display_name: string }[];
  selected: string[];
  canEdit: boolean;
}) {
  const [state, action] = useFormState<TypeState, FormData>(saveClassTypeInstructors, null);
  const [picked, setPicked] = useState<string[]>(selected);

  return (
    <form action={action} className="mt-8 border-t border-line pt-5">
      <input type="hidden" name="class_type_id" value={classTypeId} />
      <input type="hidden" name="instructor_ids" value={picked.join(",")} />
      <h2 className="s-head mb-1">Who can teach it</h2>
      <p className="mb-3 text-[13px] leading-[20px] text-ink-2">
        What the scheduler is allowed to pick from for a {typeName} class.
      </p>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      {picked.length === 0 && (
        <p className="mb-3 rounded-xl px-3 py-2.5 text-[12.5px] leading-[19px]"
           style={{ background: "var(--amber-tint)", color: "var(--ink)" }}>
          Nobody is down to teach {typeName} yet. The scheduler will leave these
          classes open rather than guess — tick whoever can take them.
        </p>
      )}

      {instructors.length === 0 ? (
        <p className="text-[13px] leading-[20px] text-ink-2">No instructors yet.</p>
      ) : (
        <ul className="flex flex-wrap gap-1.5">
          {instructors.map((p) => {
            const on = picked.includes(p.id);
            return (
              <li key={p.id}>
                <button type="button" disabled={!canEdit} aria-pressed={on}
                        onClick={() => setPicked((x) =>
                          x.includes(p.id) ? x.filter((y) => y !== p.id) : [...x, p.id])}
                        className="rounded-full px-3 py-1.5 text-[12.5px] font-medium disabled:opacity-60"
                        style={on
                          ? { background: "var(--lime-tint)", color: "var(--lime-text)",
                              boxShadow: "inset 0 0 0 1px var(--lime-text)" }
                          : { background: "var(--paper)", color: "var(--ink-2)" }}>
                  {p.display_name}
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {canEdit && instructors.length > 0 && (
        <div className="mt-3"><Save /></div>
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
