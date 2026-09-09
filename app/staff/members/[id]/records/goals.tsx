"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, inputClass } from "@/components/ui";
import { saveGoal, completeGoal, deleteGoal, type RecordState } from "./actions";

export type Goal = {
  id: string; title: string; target_type: string; target_value: number | null;
  target_date: string | null; status: string; completed_at: string | null;
  /** Counted live from check_ins since the goal was set — never a cached column. */
  done: number; met: boolean;
};

function Btn({ label, tone = "quiet" }: { label: string; tone?: "quiet" | "primary" | "danger" }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className={`shrink-0 rounded-lg px-3 py-1.5 text-[12.5px] font-medium disabled:opacity-60 ${
        tone === "primary" ? "bg-ink text-paper" : ""}`}
      style={tone === "danger" ? { color: "var(--coral-deep)" }
           : tone === "quiet" ? { color: "var(--ink-2)" } : undefined}>
      {pending ? "…" : label}
    </button>
  );
}

/**
 * Goals, measured against attendance the member actually has.
 *
 * member_goals.current_value is a stored column nothing ever moved, so every
 * goal read "0 of 12" no matter how often the member came. The count is
 * computed live from check_ins instead — and FROM THE DAY THE GOAL WAS SET,
 * because "twelve classes" agreed in March is not already met by last year.
 */
export default function GoalsPanel({ memberId, goals }: { memberId: string; goals: Goal[] }) {
  const [saveState, save] = useFormState<RecordState, FormData>(saveGoal, null);
  const [doneState, complete] = useFormState<RecordState, FormData>(completeGoal, null);
  const [delState, remove] = useFormState<RecordState, FormData>(deleteGoal, null);
  const state = saveState ?? doneState ?? delState;
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);

  const Form = ({ g }: { g?: Goal }) => (
    <form action={save} className="rounded-xl p-3" style={{ background: "var(--paper)" }}>
      <input type="hidden" name="member_id" value={memberId} />
      {g && <input type="hidden" name="goal_id" value={g.id} />}
      <input name="title" required defaultValue={g?.title ?? ""}
             placeholder="Twelve classes before the wedding" className={inputClass} />
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <select name="target_type" defaultValue={g?.target_type ?? "class_count"}
                aria-label="What to measure"
                className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink">
          <option value="class_count">Classes attended</option>
          <option value="custom">Something else — tracked by hand</option>
        </select>
        <input name="target_value" type="number" min={1} max={999}
               defaultValue={g?.target_value ?? ""} placeholder="How many"
               aria-label="Target"
               className="w-[110px] rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink" />
        <input name="target_date" type="date" defaultValue={g?.target_date ?? ""}
               aria-label="By when"
               className="rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink" />
        <span className="ml-auto flex items-center gap-2">
          <Btn label={g ? "Save" : "Set goal"} tone="primary" />
          <button type="button" onClick={() => { setAdding(false); setEditing(null); }}
                  className="text-[12.5px] text-ink-3">Cancel</button>
        </span>
      </div>
    </form>
  );

  const active = goals.filter((g) => g.status === "active");
  const closed = goals.filter((g) => g.status !== "active");

  const Row = ({ g }: { g: Goal }) => {
    const pct = g.target_value ? Math.min(100, Math.round((g.done / g.target_value) * 100)) : null;
    return (
      <li className={`s-row ${g.status === "active" ? "" : "opacity-60"}`}>
        {editing === g.id ? <Form g={g} /> : (
          <>
            <div className="flex items-baseline gap-2">
              <span className="flex-1 text-[13.5px] font-medium leading-5 text-ink">{g.title}</span>
              {g.target_value != null && (
                <span className="num shrink-0 text-[13px] leading-5"
                      style={{ color: g.met ? "var(--lime-text)" : "var(--ink-2)" }}>
                  {g.done} of {g.target_value}
                </span>
              )}
            </div>
            {pct !== null && (
              <div className="mt-1.5 h-1.5 w-full overflow-hidden rounded-full" style={{ background: "var(--line)" }}>
                <div className="h-full rounded-full"
                     style={{ width: `${pct}%`,
                              background: g.met ? "var(--lime-text)" : "var(--ink-3)" }} />
              </div>
            )}
            <div className="mt-1.5 flex items-center gap-1">
              {g.target_date && (
                <span className="text-[11.5px] leading-4 text-ink-3">
                  by {new Date(g.target_date + "T12:00:00Z").toLocaleDateString("en-GB",
                      { day: "numeric", month: "short", year: "numeric" })}
                  {" · "}
                </span>
              )}
              <button onClick={() => setEditing(g.id)} className="text-[12.5px] text-ink-3">Edit</button>
              <span aria-hidden className="text-ink-3">·</span>
              <form action={complete} className="inline">
                <input type="hidden" name="member_id" value={memberId} />
                <input type="hidden" name="goal_id" value={g.id} />
                {g.status !== "active" && <input type="hidden" name="reopen" value="1" />}
                <Btn label={g.status === "active" ? "Mark done" : "Reopen"} />
              </form>
              <span aria-hidden className="text-ink-3">·</span>
              <form action={remove} className="inline">
                <input type="hidden" name="member_id" value={memberId} />
                <input type="hidden" name="goal_id" value={g.id} />
                <Btn label="Delete" tone="danger" />
              </form>
            </div>
          </>
        )}
      </li>
    );
  };

  return (
    <section className="s-card p-5">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h2 className="s-head">Goals</h2>
        {!adding && (
          <button onClick={() => setAdding(true)} className="text-[12.5px] font-medium text-ink-2">
            Set a goal
          </button>
        )}
      </div>
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      {adding && <div className="mb-3"><Form /></div>}

      {goals.length === 0 && !adding ? (
        <p className="text-[13px] leading-[20px] text-ink-2">
          Nothing set. A class count is measured against their real attendance,
          from the day you set it.
        </p>
      ) : (
        <ul>{active.map((g) => <Row key={g.id} g={g} />)}</ul>
      )}
      {closed.length > 0 && (
        <details className="mt-3">
          <summary className="cursor-pointer text-[12.5px] text-ink-3">{closed.length} finished</summary>
          <ul className="mt-1">{closed.map((g) => <Row key={g.id} g={g} />)}</ul>
        </details>
      )}
    </section>
  );
}
