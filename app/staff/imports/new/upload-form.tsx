"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { uploadImport, type ImportState } from "../actions";

const TYPES = [
  {
    value: "members",
    label: "Members",
    blurb: "Name, email, phone, when they joined. Do this one first — everything else matches on email.",
    columns: "email · name (or first and last) · phone · joined · status",
  },
  {
    value: "memberships",
    label: "Memberships",
    blurb: "What each member is on, and what they actually paid. The price is taken from your file, not from the plan, so nobody is silently repriced.",
    columns: "email · plan name · status · starts · expires · price paid · credits left",
  },
  {
    value: "attendance",
    label: "Attendance",
    blurb: "Past visits. This is what makes the health score and the Morning Brief mean anything on day one — without it every member looks new.",
    columns: "email · visit date",
  },
];

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button className={buttonClass} disabled={pending}>
      {pending ? "Reading the file…" : "Upload and map columns"}
    </button>
  );
}

export default function UploadForm() {
  const [state, action] = useFormState<ImportState, FormData>(uploadImport, null);

  return (
    <form action={action} className="max-w-2xl space-y-6">
      {state && <Notice kind="error">{state.error}</Notice>}

      <fieldset className="space-y-2">
        <legend className="mb-2 text-sm font-medium">What is in this file?</legend>
        {TYPES.map((t, i) => (
          <label key={t.value}
                 className="flex cursor-pointer gap-3 rounded border border-line bg-white p-3 hover:bg-paper">
            <input type="radio" name="type" value={t.value} defaultChecked={i === 0}
                   className="mt-1 shrink-0" required />
            <span className="min-w-0">
              <span className="block text-sm font-medium">{t.label}</span>
              <span className="mt-0.5 block text-xs leading-relaxed text-ink-2">{t.blurb}</span>
              <span className="mt-1 block text-xs text-ink-3">Columns it looks for: {t.columns}</span>
            </span>
          </label>
        ))}
      </fieldset>

      <Field label="CSV file">
        <input name="file" type="file" accept=".csv,text/csv" required
               className="block w-full text-sm file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-sm file:text-white" />
        <p className="mt-1 text-xs text-ink-3">
          Export from whatever you use now — the first row must be the column
          names. Nothing in your studio changes from uploading; the next screen
          shows you what would happen before anything is written.
        </p>
      </Field>

      <div className="flex items-center gap-4">
        <Submit />
        <Link href="/imports" className="text-sm text-ink-2 underline underline-offset-4">Cancel</Link>
      </div>
    </form>
  );
}
