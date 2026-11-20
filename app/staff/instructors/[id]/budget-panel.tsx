"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveBudget, type BudgetState } from "./budget-actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Set budget"}</button>;
}

/**
 * Decision 106 (a) — "Core classes per week": how many of this coach's classes
 * a week should earn core, the top the weekly growth review proposes. Seeded
 * from the studio's pattern; a manager can change it here. It informs the
 * review (a class past it is flagged), it never blocks.
 */
export default function BudgetPanel({ instructorId, current }: { instructorId: string; current: number | null }) {
  const [state, action] = useFormState<BudgetState, FormData>(saveBudget, null);
  return (
    <form action={action} className="mt-3 rounded border border-line bg-surface p-4">
      <input type="hidden" name="instructor_id" value={instructorId} />
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <label className="mt-2 block">
        <span className="mb-1 block text-[13px] font-medium text-ink">Core classes per week</span>
        <select name="n" defaultValue={current ?? ""}
          className="rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none">
          {current == null && <option value="" disabled>Not set</option>}
          {Array.from({ length: 21 }, (_, k) => k + 1).map((v) => (
            <option key={v} value={v}>{v}</option>
          ))}
        </select>
      </label>
      <p className="mt-1 text-[12px] text-ink-3">
        The weekly growth review proposes this coach&rsquo;s top {current ?? "N"} class
        {(current ?? 2) === 1 ? "" : "es"} a week as core, the rest as flex.
      </p>
      <div className="mt-3"><Save /></div>
    </form>
  );
}
