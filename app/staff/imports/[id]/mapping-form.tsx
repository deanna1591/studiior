"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass, inputClass } from "@/components/ui";
import { runDryRun, type ImportState } from "../actions";

export type FieldDef = { key: string; label: string; required?: boolean };

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Checking…" : label}</button>;
}

/**
 * The guess is a starting point, never the decision.
 *
 * Every field is a select over the file's own headers, pre-filled from
 * guessMapping and freely changeable. A column mapped wrong here writes wrong
 * data on commit, so the owner sees the guess rather than inheriting it.
 */
export default function MappingForm({
  id, fields, headers, mapping, sample, hasRun,
}: {
  id: string;
  fields: FieldDef[];
  headers: string[];
  mapping: Record<string, string>;
  sample: Record<string, string>;
  hasRun: boolean;
}) {
  const [state, action] = useFormState<ImportState, FormData>(runDryRun, null);

  return (
    <form action={action} className="space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      <input type="hidden" name="id" value={id} />

      <div className="overflow-x-auto rounded border border-stone-200 bg-white">
        <table className="w-full text-sm">
          <thead className="border-b border-stone-200 bg-stone-50 text-left text-xs uppercase tracking-wide text-stone-500">
            <tr>
              <th className="px-3 py-2 font-medium">Studiior field</th>
              <th className="px-3 py-2 font-medium">Column in your file</th>
              <th className="px-3 py-2 font-medium">First row reads</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-stone-100">
            {fields.map((f) => {
              const chosen = mapping[f.key] ?? "";
              return (
                <tr key={f.key}>
                  <td className="whitespace-nowrap px-3 py-2">
                    {f.label}
                    {f.required && <span className="ml-1 text-rose-600" title="Required">*</span>}
                  </td>
                  <td className="px-3 py-2">
                    <select name={`map_${f.key}`} defaultValue={chosen} className={inputClass}>
                      <option value="">— not in this file —</option>
                      {headers.map((h) => <option key={h} value={h}>{h}</option>)}
                    </select>
                  </td>
                  <td className="max-w-[16rem] truncate px-3 py-2 text-stone-500">
                    {chosen ? (sample[chosen] || <span className="italic text-stone-400">empty</span>) : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-stone-500">
        Dates are read one column at a time, not one row at a time: 03/04/2024 is
        ambiguous alone, so the whole column decides, and a column that is
        genuinely mixed is left for you to fix rather than guessed at.
      </p>

      <Submit label={hasRun ? "Re-check with this mapping" : "Check the file"} />
    </form>
  );
}
