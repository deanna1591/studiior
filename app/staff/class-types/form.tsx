"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveClassType, uploadClassTypeImage, type SetupState } from "../setup/actions";

export type ClassTypeDraft = {
  id?: string; name: string; description: string | null; duration_minutes: number;
  default_capacity: number; difficulty: string | null; color: string | null; status: string;
  image_url?: string | null;
};

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function ClassTypeForm({ draft, mode }: { draft: ClassTypeDraft; mode: "create" | "edit" }) {
  const [state, action] = useFormState<SetupState, FormData>(saveClassType, null);
  const [imgState, imgAction] = useFormState<SetupState, FormData>(uploadClassTypeImage, null);
  return (
    <>
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
      <p className="-mt-2 text-xs text-ink-3">
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
                 className="h-9 w-20 rounded border border-line-2" />
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
        <Link href="/class-types" className="text-sm text-ink-2 underline underline-offset-4">Cancel</Link>
      </div>
    </form>

    {/* A second form, not a field in the first one: an image upload is a
        separate request and putting it inside the save form would mean a
        member could not change a photograph without re-submitting everything
        else. Only offered once the class type exists — an image needs a row to
        belong to. */}
    {draft.id && (
      <form action={imgAction} className="mt-8 max-w-md space-y-3 border-t border-line pt-6">
        {imgState && <Notice kind="error">{imgState.error}</Notice>}
        <input type="hidden" name="id" value={draft.id} />
        <span className="block text-[13px] font-medium leading-[18px] text-ink">Photo</span>
        {draft.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={draft.image_url} alt="" className="h-32 w-full rounded-lg border border-line object-cover" />
        ) : (
          <p className="text-[12px] leading-4 text-ink-3">
            No photo yet. Members see a card with no picture on it.
          </p>
        )}
        <input name="image" type="file" accept="image/png,image/jpeg,image/webp"
               className="block w-full text-[13px] file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-[13px] file:text-paper" />
        <p className="text-[12px] leading-4 text-ink-3">
          Shown on the member&rsquo;s class list and detail screen. Landscape, under 2 MB.
        </p>
        <Submit label="Upload" />
      </form>
    )}

    </>
  );
}
