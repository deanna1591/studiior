"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveClassType, type SetupState } from "../setup/actions";

export type ClassTypeDraft = {
  id?: string; name: string; description: string | null; duration_minutes: number;
  default_capacity: number; difficulty: string | null; color: string | null; status: string;
};

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function ClassTypeForm({ draft, mode }: { draft: ClassTypeDraft; mode: "create" | "edit" }) {
  const [state, action] = useFormState<SetupState, FormData>(saveClassType, null);
  return (
    <form action={action} className="max-w-md space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <Field label="Name">
        <input name="name" required defaultValue={draft.name} className={inputClass} placeholder="Reformer Flow" />
      </Field>
      <Field label="Description">
        <textarea name="description" rows={2} defaultValue={draft.description ?? ""}
                  className={inputClass} placeholder="What a member is turning up to." />
      </Field>
      <div className="grid grid-cols-2 gap-3">
        <Field label="Duration (minutes)">
          <input name="duration_minutes" type="number" min={1} required
                 defaultValue={draft.duration_minutes || ""} className={inputClass} placeholder="50" />
        </Field>
        <Field label="Default capacity">
          <input name="default_capacity" type="number" min={1} required
                 defaultValue={draft.default_capacity || ""} className={inputClass} placeholder="8" />
        </Field>
      </div>
      <p className="-mt-2 text-xs text-stone-500">
        Both are starting points: a class created from this type inherits them and
        can override either.
      </p>
      <div className="grid grid-cols-2 gap-3">
        <Field label="Difficulty">
          <select name="difficulty" defaultValue={draft.difficulty ?? ""} className={inputClass}>
            <option value="">Not set</option>
            <option value="beginner">Beginner</option>
            <option value="all levels">All levels</option>
            <option value="intermediate">Intermediate</option>
            <option value="advanced">Advanced</option>
          </select>
        </Field>
        <Field label="Colour">
          <input name="color" type="color" defaultValue={draft.color ?? "#2F4F4F"}
                 className="h-9 w-20 rounded border border-stone-300" />
        </Field>
      </div>
      {mode === "edit" && (
        <Field label="Status">
          <select name="status" defaultValue={draft.status} className={inputClass}>
            <option value="active">Active</option>
            <option value="archived">Archived — not offered for new classes</option>
          </select>
        </Field>
      )}
      <div className="flex items-center gap-4">
        <Submit label={mode === "create" ? "Add class type" : "Save changes"} />
        <Link href="/class-types" className="text-sm text-stone-600 underline underline-offset-4">Cancel</Link>
      </div>
    </form>
  );
}
