"use client";

import { useFormState, useFormStatus } from "react-dom";
import { createAnnouncement, updateAnnouncement, type AnnFormState } from "./actions";
import { Notice, buttonQuietClass } from "@/components/ui";

function Save({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

const field = "w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

export type AnnValues = {
  id?: string; title: string; body: string; audience: string;
  pinned: boolean; starts_on: string; ends_on: string;
};

/**
 * Create or edit an announcement. Same fields either way; the id (if present)
 * routes it to update. A cover photo is offered only on create — on edit it
 * is set on the overview, where the focal point can be tuned against a preview.
 */
export default function AnnouncementForm({ mode, values }: {
  mode: "new" | "edit"; values: AnnValues;
}) {
  const action = mode === "new" ? createAnnouncement : updateAnnouncement;
  const [state, formAction] = useFormState<AnnFormState, FormData>(action, null);

  return (
    <form action={formAction} className="max-w-2xl space-y-4">
      {state?.error && <Notice kind="error">{state.error}</Notice>}
      {values.id && <input type="hidden" name="announcement_id" value={values.id} />}

      <label className="block">
        <span className="mb-1 block text-[13px] font-medium text-ink">Title</span>
        <input name="title" defaultValue={values.title} className={field}
               placeholder="Closed for the holiday" required />
      </label>

      <label className="block">
        <span className="mb-1 block text-[13px] font-medium text-ink">Body</span>
        <textarea name="body" defaultValue={values.body} rows={5} className={field}
                  placeholder="What members need to know." required />
      </label>

      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Starts</span>
          <input type="date" name="starts_on" defaultValue={values.starts_on} className={field} />
        </label>
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Ends <span className="text-ink-3">(optional)</span></span>
          <input type="date" name="ends_on" defaultValue={values.ends_on} className={field} />
        </label>
      </div>

      <label className="block">
        <span className="mb-1 block text-[13px] font-medium text-ink">Who sees it</span>
        <select name="audience" defaultValue={values.audience} className={field}>
          <option value="members">Members</option>
          <option value="instructors">Instructors</option>
          <option value="both">Members and instructors</option>
        </select>
        <span className="mt-1 block text-[12px] text-ink-3">
          A closure is for both; a new offer is members only. Instructors see theirs in the portal.
        </span>
      </label>

      <label className="flex items-start gap-2.5">
        <input type="checkbox" name="pinned" defaultChecked={values.pinned} className="mt-1" />
        <span className="text-[13px] leading-[19px] text-ink">
          Pin it — it stays at the top and cannot be dismissed until it ends.
        </span>
      </label>

      {mode === "new" && (
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Photo <span className="text-ink-3">(optional)</span></span>
          <input name="cover" type="file" accept="image/png,image/jpeg,image/webp"
                 className="block w-full text-[13px] file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-[13px] file:text-surface" />
          <span className="mt-1 block text-[12px] text-ink-3">You can set where it crops after saving.</span>
        </label>
      )}

      <Save label={mode === "new" ? "Create as draft" : "Save changes"} />
    </form>
  );
}
