"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { deletePlan, setPlanStatus, type PlanFormState } from "../actions";

function Btn({ label, danger }: { label: string; danger?: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      className={`rounded border px-3 py-1.5 text-sm disabled:opacity-50 ${
        danger
          ? "border-coral text-ink hover:border-coral"
          : "border-line-2 hover:border-ink-3"
      }`}
    >
      {pending ? "…" : label}
    </button>
  );
}

export default function PlanLifecycle({
  id, status, activeMemberships,
}: {
  id: string; status: string; activeMemberships: number;
}) {
  const [archiveState, archiveAction] = useFormState<PlanFormState, FormData>(setPlanStatus, null);
  const [deleteState, deleteAction] = useFormState<PlanFormState, FormData>(deletePlan, null);

  return (
    <section className="mt-10 max-w-2xl rounded border border-line bg-white p-4">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-ink-3">
        Retiring this plan
      </h2>

      {archiveState && <div className="mt-3"><Notice kind="error">{archiveState.error}</Notice></div>}
      {deleteState && <div className="mt-3"><Notice kind="error">{deleteState.error}</Notice></div>}

      <p className="mt-2 text-sm leading-relaxed text-ink-2">
        Archiving stops the plan being sold. Everyone already on it keeps it, at the
        price they bought at, and keeps booking normally.
      </p>

      <div className="mt-3 flex items-center gap-3">
        <form action={archiveAction}>
          <input type="hidden" name="id" value={id} />
          <input type="hidden" name="status" value={status === "active" ? "archived" : "active"} />
          <Btn label={status === "active" ? "Archive plan" : "Restore plan"} />
        </form>

        {activeMemberships === 0 ? (
          <form action={deleteAction}>
            <input type="hidden" name="id" value={id} />
            <Btn label="Delete permanently" danger />
          </form>
        ) : (
          <span className="text-sm text-ink-3">
            Cannot be deleted — {activeMemberships} member
            {activeMemberships === 1 ? " is" : "s are"} on it. Archive instead.
          </span>
        )}
      </div>

      <p className="mt-3 text-xs text-ink-3">
        Deleting is only offered for a plan nobody ever bought. The database refuses
        the rest regardless of what this screen shows.
      </p>
    </section>
  );
}
