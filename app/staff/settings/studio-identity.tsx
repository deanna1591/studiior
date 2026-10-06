"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveStudioName, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 71 — studio identity after onboarding. The name is editable by the
 * owner (studios RLS is owner-write); a manager sees it read-only. The member
 * app address, time zone, currency and country are shown read-only with a note
 * to contact Studiior — the slug is the member host and the locale fields drive
 * every day boundary, so they are not a self-serve change in V1.
 */
export default function StudioIdentityPanel({
  name, slug, timezone, currency, country, canEditName, memberDomain,
}: {
  name: string;
  slug: string;
  timezone: string;
  currency: string;
  country: string | null;
  canEditName: boolean;
  memberDomain: string;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveStudioName, null);

  const ReadOnly = ({ label, value }: { label: string; value: string }) => (
    <div>
      <span className="block text-[12px] text-ink-3">{label}</span>
      <span className="block text-[14px] text-ink-2">{value || "—"}</span>
    </div>
  );

  return (
    <form action={action} className="max-w-2xl space-y-3">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        {canEditName ? (
          <>
            <label className="block text-[13px] font-medium text-ink" htmlFor="studio_name">Studio name</label>
            <div className="mt-1.5 flex items-center gap-2">
              <input id="studio_name" name="name" defaultValue={name} required
                     className={`${inputClass} max-w-sm`} />
              <Save />
            </div>
          </>
        ) : (
          <>
            <ReadOnly label="Studio name" value={name} />
            <p className="mt-1 text-[12px] leading-[18px] text-ink-3">Owner only.</p>
          </>
        )}
      </div>

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <div className="grid grid-cols-2 gap-x-6 gap-y-3">
          <ReadOnly label="Member app address" value={`${slug}.${memberDomain}`} />
          <ReadOnly label="Time zone" value={timezone} />
          <ReadOnly label="Currency" value={currency} />
          <ReadOnly label="Country" value={country ?? ""} />
        </div>
        <p className="mt-3 border-t border-line pt-3 text-[12px] leading-[18px] text-ink-3">
          Contact Studiior to change your member app address, time zone, currency or country.
        </p>
      </div>
    </form>
  );
}
