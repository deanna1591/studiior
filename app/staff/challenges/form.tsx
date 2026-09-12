"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { createChallenge, type ChallengeFormState } from "./actions";

type Template = { id: string; title: string; type: string; goal_value: number;
  duration_days: number; description: string | null; reward_description: string | null };
type ClassType = { id: string; name: string };

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="rounded-full bg-ink px-5 py-2.5 text-[14px] font-semibold text-surface disabled:opacity-60">
      {pending ? "Creating…" : "Create as draft"}
    </button>
  );
}

const field = "w-full rounded-lg border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink";
const lbl = "block text-[12px] font-semibold text-ink-2 mb-1";

export default function ChallengeForm({
  templates, classTypes, today,
}: {
  templates: Template[]; classTypes: ClassType[]; today: string;
}) {
  const [state, action] = useFormState<ChallengeFormState, FormData>(createChallenge, null);
  const [type, setType] = useState("class_count");
  const [tpl, setTpl] = useState("");

  // Prefill from a template — a starting point a studio edits, not a lock.
  const t = templates.find((x) => x.id === tpl);

  return (
    <form action={action} className="max-w-xl space-y-4">
      {state?.error && (
        <p className="border-l-[3px] border-coral bg-coral-tint px-3 py-2 text-[13px] text-ink">{state.error}</p>
      )}

      <div>
        <label className={lbl}>Start from a template (optional)</label>
        <select name="template_id" value={tpl} className={field}
                onChange={(e) => {
                  setTpl(e.target.value);
                  const nt = templates.find((x) => x.id === e.target.value);
                  if (nt) setType(nt.type);
                }}>
          <option value="">Blank</option>
          {templates.map((x) => <option key={x.id} value={x.id}>{x.title}</option>)}
        </select>
      </div>

      <div>
        <label className={lbl}>Title</label>
        <input name="title" required defaultValue={t?.title ?? ""} className={field}
               placeholder="e.g. Ten classes in October" />
      </div>

      <div>
        <label className={lbl}>Description (optional)</label>
        <textarea name="description" defaultValue={t?.description ?? ""} className={field} rows={2} />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className={lbl}>Goal type</label>
          <select name="type" value={type} onChange={(e) => setType(e.target.value)} className={field}>
            <option value="class_count">Classes attended</option>
            <option value="streak">Weekly streak</option>
            <option value="class_type_count">Classes of certain types</option>
          </select>
        </div>
        <div>
          <label className={lbl}>{type === "streak" ? "Weeks in a row" : "Number of classes"}</label>
          <input name="goal_value" type="number" min={1} required
                 defaultValue={t?.goal_value ?? ""} className={`${field} num`} />
        </div>
      </div>

      {type === "class_type_count" && (
        <div>
          <label className={lbl}>Which class types count</label>
          <div className="flex flex-wrap gap-2">
            {classTypes.map((c) => (
              <label key={c.id} className="flex items-center gap-1.5 rounded-full border border-line-2 px-3 py-1.5 text-[13px]">
                <input type="checkbox" name="class_type_ids" value={c.id} /> {c.name}
              </label>
            ))}
          </div>
          <p className="mt-1 text-[11px] text-ink-3">Leave all unticked and any class counts.</p>
        </div>
      )}

      <div className="grid grid-cols-3 gap-3">
        <div><label className={lbl}>Starts</label>
          <input name="starts_on" type="date" required defaultValue={today} className={`${field} num`} /></div>
        <div><label className={lbl}>Ends</label>
          <input name="ends_on" type="date" required className={`${field} num`} /></div>
        <div><label className={lbl}>Join by</label>
          <input name="join_deadline" type="date" required className={`${field} num`} /></div>
      </div>
      <p className="text-[11px] text-ink-3">The join deadline must fall between the start and end.</p>

      <div>
        <label className={lbl}>Reward (optional)</label>
        <input name="reward" defaultValue={t?.reward_description ?? ""} className={field}
               placeholder="A free class, a shout-out…" />
        <p className="mt-1 text-[11px] text-ink-3">Text only. You fulfil it — nothing here is money owed.</p>
      </div>

      <label className="flex items-center gap-2 text-[13px] text-ink">
        <input type="checkbox" name="leaderboard" />
        Show a leaderboard <span className="text-ink-3">— off by default; members always see their own progress either way.</span>
      </label>

      <Submit />
    </form>
  );
}
