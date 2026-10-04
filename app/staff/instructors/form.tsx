"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveInstructor, type SetupState } from "../setup/actions";

export type InstructorDraft = {
  id?: string; display_name: string; bio: string | null; avatar_url: string | null;
  color: string | null; certifications: string[]; status: string; hasLogin?: boolean;
};

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function InstructorForm({ draft, mode }: { draft: InstructorDraft; mode: "create" | "edit" }) {
  const [state, action] = useFormState<SetupState, FormData>(saveInstructor, null);
  return (
    <form action={action} className="max-w-md space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <Field label="Display name">
        <input name="display_name" required defaultValue={draft.display_name}
               className={inputClass} placeholder="Ada Example" />
        <p className="mt-1 text-xs text-ink-3">
          What members see on the schedule.
        </p>
      </Field>
      <Field label="Bio">
        <textarea name="bio" rows={3} defaultValue={draft.bio ?? ""} className={inputClass}
                  placeholder="A couple of lines for the member app." />
      </Field>
      {/* Decision 60: the photo is uploaded, not pasted. On CREATE there is no
          instructor id yet to key the storage path, so the Upload control lives
          on the edit page — a new instructor gets a photo right after adding. */}
      {mode === "create" && (
        <p className="rounded border border-line bg-paper px-3 py-2 text-xs leading-relaxed text-ink-2">
          Add a photo after you add the instructor — it uploads from their page.
        </p>
      )}
      <Field label="Certifications">
        <textarea name="certifications" rows={3} className={inputClass}
                  defaultValue={draft.certifications.join("\n")}
                  placeholder={"BASI Comprehensive\nPre/postnatal"} />
        <p className="mt-1 text-xs text-ink-3">One per line, or comma separated.</p>
      </Field>
      <Field label="Colour">
        <input name="color" type="color" defaultValue={draft.color ?? "#CD853F"}
               className="h-9 w-20 rounded border border-line-2" />
      </Field>
      <p className="rounded border border-line bg-paper px-3 py-2 text-xs leading-relaxed text-ink-2">
        {draft.hasLogin
          ? "This instructor has a staff login and can sign in to see their own schedule."
          : "This is a teaching record, not an account — no login, no invite, nothing to sign in with. Give them one later from staff settings if they need the instructor portal."}
      </p>
      <div className="flex items-center gap-4">
        <Submit label={mode === "create" ? "Add instructor" : "Save changes"} />
        <Link href="/instructors" className="text-sm text-ink-2 underline underline-offset-4">Cancel</Link>
      </div>
    </form>
  );
}
