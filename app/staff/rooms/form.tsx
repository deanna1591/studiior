"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { saveRoom, type SetupState } from "../setup/actions";

export type RoomDraft = {
  id?: string; name: string; capacity: number; color: string | null; status: string;
};

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export default function RoomForm({ draft, mode }: { draft: RoomDraft; mode: "create" | "edit" }) {
  const [state, action] = useFormState<SetupState, FormData>(saveRoom, null);
  return (
    <form action={action} className="max-w-md space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <Field label="Name">
        <input name="name" required defaultValue={draft.name} className={inputClass}
               placeholder="Reformer Studio" />
      </Field>
      <Field label="Capacity">
        <input name="capacity" type="number" min={1} required defaultValue={draft.capacity || ""}
               className={inputClass} placeholder="8" />
        <p className="mt-1 text-xs text-stone-500">
          How many people fit. A class in this room defaults to it, and capacity
          cannot later be cut below what is already booked (§5).
        </p>
      </Field>
      <Field label="Colour">
        <input name="color" type="color" defaultValue={draft.color ?? "#8FBC8F"}
               className="h-9 w-20 rounded border border-stone-300" />
      </Field>
      {mode === "edit" && (
        <Field label="Status">
          <select name="status" defaultValue={draft.status} className={inputClass}>
            <option value="active">Active</option>
            <option value="archived">Archived — not offered for new classes</option>
          </select>
        </Field>
      )}
      <div className="flex items-center gap-4">
        <Submit label={mode === "create" ? "Add room" : "Save changes"} />
        <Link href="/rooms" className="text-sm text-stone-600 underline underline-offset-4">Cancel</Link>
      </div>
    </form>
  );
}
