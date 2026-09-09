"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { archiveRecord, restoreRecord, deleteRecord, type ArchiveState } from "./archive-actions";

function Btn({ label, tone = "quiet" }: { label: string; tone?: "quiet" | "danger" }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className="m-tap rounded-lg border px-3 py-1.5 text-[13px] font-medium disabled:opacity-60"
      style={tone === "danger"
        ? { borderColor: "var(--coral)", color: "var(--coral-deep)" }
        : { borderColor: "var(--line-2)", color: "var(--ink-2)" }}
    >
      {pending ? "…" : label}
    </button>
  );
}

/**
 * Archive, restore and delete for a class type, a room or an instructor.
 *
 * ARCHIVE IS THE NORMAL ACTION and reads like one; delete is the outlined
 * coral, and the database refuses it whenever anything points at the record.
 * The confirm step is not a generic "are you sure" — it is the sentence the
 * database composed, with the counts in it: "Amihan Teacher is teaching 14
 * classes. Archiving leaves them unstaffed and open for another instructor to
 * pick up — 9 members are already booked."
 */
export default function ArchiveControls({
  kind, id, archived,
}: {
  kind: "class_type" | "room" | "instructor";
  id: string;
  archived: boolean;
}) {
  const [archState, archive] = useFormState<ArchiveState, FormData>(archiveRecord, null);
  const [restState, restore] = useFormState<ArchiveState, FormData>(restoreRecord, null);
  const [delState, remove] = useFormState<ArchiveState, FormData>(deleteRecord, null);
  const state = archState ?? restState ?? delState;
  const needsConfirm = archState && !archState.ok && "confirm" in archState;

  const noun = kind === "class_type" ? "class type" : kind === "room" ? "room" : "instructor";

  return (
    <section className="mt-8 border-t border-line pt-5">
      {state && (
        <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>
      )}

      {archived ? (
        <div className="flex flex-wrap items-center gap-3">
          <p className="m-sub flex-1 text-ink-2">
            This {noun} is archived. Members cannot see it; you can.
          </p>
          <form action={restore}>
            <input type="hidden" name="kind" value={kind} />
            <input type="hidden" name="id" value={id} />
            <Btn label="Restore" />
          </form>
        </div>
      ) : (
        <div className="flex flex-wrap items-center gap-3">
          <p className="m-sub flex-1 text-ink-2">
            Archiving hides this {noun} from members and keeps it on everything
            it is already part of.
          </p>
          <form action={archive}>
            <input type="hidden" name="kind" value={kind} />
            <input type="hidden" name="id" value={id} />
            {/* The second press carries the flag. Rendered only after the
                database has said what will happen, so it can never be the
                first thing anybody clicks. */}
            {needsConfirm && <input type="hidden" name="confirm" value="1" />}
            <Btn label={needsConfirm ? "Yes, archive it" : "Archive"} />
          </form>
        </div>
      )}

      <form action={remove} className="mt-4">
        <input type="hidden" name="kind" value={kind} />
        <input type="hidden" name="id" value={id} />
        <Btn label={`Delete this ${noun}`} tone="danger" />
        <p className="m-micro mt-2 text-ink-3">
          Only possible while nothing refers to it. Once a class has used it,
          deleting would take it off that class&rsquo;s record, so it is refused.
        </p>
      </form>
    </section>
  );
}
