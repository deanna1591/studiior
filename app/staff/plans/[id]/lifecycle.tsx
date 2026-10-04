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
  id, status, totalMemberships,
}: {
  id: string; status: string; totalMemberships: number;
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

        {/* Decision 57 follow-up: the FK blocks deletion on ANY membership (any
            status), so the Delete button shows only when there are NONE at all.
            Otherwise the sentence + an Archive-instead button (when still
            active) — never a Delete button that would hit the raw FK error. */}
        {totalMemberships === 0 ? (
          <form action={deleteAction}>
            <input type="hidden" name="id" value={id} />
            <Btn label="Delete permanently" danger />
          </form>
        ) : (
          <>
            <span className="text-sm text-ink-3">
              This plan has {totalMemberships} membership{totalMemberships === 1 ? "" : "s"} on it,
              so it can&rsquo;t be deleted. Archive it instead — archived plans can&rsquo;t be bought
              and keep their history.
            </span>
            {status === "active" && (
              <form action={archiveAction}>
                <input type="hidden" name="id" value={id} />
                <input type="hidden" name="status" value="archived" />
                <Btn label="Archive instead" />
              </form>
            )}
          </>
        )}
      </div>

      <p className="mt-3 text-xs text-ink-3">
        Deleting is only offered for a plan nobody ever bought. The database refuses
        the rest regardless of what this screen shows.
      </p>
    </section>
  );
}
