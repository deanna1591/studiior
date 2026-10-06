"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveStoreApps, type PlainState } from "../actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field =
  "w-full rounded border border-line bg-surface px-2.5 py-1.5 text-[14px] text-ink";

export default function StoreAppsForm({
  androidPackage, fingerprints, teamId, bundleId,
}: {
  androidPackage: string;
  fingerprints: string;
  teamId: string;
  bundleId: string;
}) {
  const [state, action] = useFormState<PlainState, FormData>(saveStoreApps, null);

  return (
    <form action={action} className="max-w-2xl space-y-3">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">Android</p>

        <label className="mt-2 block text-[12px] text-ink-2" htmlFor="android_package">
          Android package name (from PWABuilder)
        </label>
        <input id="android_package" name="android_package" defaultValue={androidPackage}
               placeholder="app.studiior.yourstudio" className={`${field} mt-1`} />

        <label className="mt-3 block text-[12px] text-ink-2" htmlFor="android_sha256_fingerprints">
          SHA-256 certificate fingerprints (from Play Console → Setup → App integrity; one per line or comma-separated)
        </label>
        <textarea id="android_sha256_fingerprints" name="android_sha256_fingerprints" rows={3}
                  defaultValue={fingerprints}
                  placeholder="AA:BB:CC:…:99" className={`${field} mt-1 font-mono text-[12px]`} />
      </div>

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">iPhone</p>

        <label className="mt-2 block text-[12px] text-ink-2" htmlFor="ios_team_id">
          Apple Team ID (10 characters, from developer.apple.com → Membership)
        </label>
        <input id="ios_team_id" name="ios_team_id" defaultValue={teamId}
               placeholder="ABCDE12345" maxLength={10} className={`${field} mt-1 w-40`} />

        <label className="mt-3 block text-[12px] text-ink-2" htmlFor="ios_bundle_id">
          iOS bundle ID
        </label>
        <input id="ios_bundle_id" name="ios_bundle_id" defaultValue={bundleId}
               placeholder="app.studiior.yourstudio" className={`${field} mt-1`} />
      </div>

      <div><Save /></div>
    </form>
  );
}
