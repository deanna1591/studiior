"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveLocationGeofence, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const field = "w-full rounded border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink outline-none";

type Loc = {
  name?: string | null;
  address?: unknown;
  latitude: number | null; longitude: number | null;
  self_checkin_radius_m: number; self_checkin_accuracy_cap_m: number;
  self_checkin_requires_location: boolean;
} | null;

/**
 * Decision 35 — the geofence for member self check-in. No paid geocoding key, so
 * this is plain lat/lng inputs with an "open in Google Maps" link to find and
 * verify them; the radius and the accuracy cap sit beside it, and a switch turns
 * the location requirement off (trust-based check-in) for a studio that wants it.
 */
export default function LocationPanel({ loc }: { loc: Loc }) {
  const [state, action] = useFormState<PlainState, FormData>(saveLocationGeofence, null);
  const [requires, setRequires] = useState(loc?.self_checkin_requires_location ?? true);

  const addr = loc?.address as Record<string, string> | null | undefined;
  const addrText = addr
    ? [addr.line1, addr.line2, addr.city, addr.postcode, addr.country].filter(Boolean).join(", ")
    : "";
  const mapsHref =
    loc?.latitude != null && loc?.longitude != null
      ? `https://www.google.com/maps?q=${loc.latitude},${loc.longitude}`
      : `https://www.google.com/maps/search/${encodeURIComponent(addrText || loc?.name || "")}`;

  return (
    <form action={action} className="max-w-2xl space-y-4">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}

      <p className="text-[13px] leading-[19px] text-ink-2">
        Set where the studio is, and a member can check themselves in from their phone
        when they arrive. Find the coordinates in{" "}
        <a href={mapsHref} target="_blank" rel="noopener noreferrer"
           className="text-lime-text underline underline-offset-4">Google Maps</a>{" "}
        — drop a pin on the door, right-click it, and copy the two numbers.
      </p>

      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Latitude</span>
          <input name="latitude" defaultValue={loc?.latitude ?? ""} className={field}
                 inputMode="decimal" placeholder="14.5995" />
        </label>
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Longitude</span>
          <input name="longitude" defaultValue={loc?.longitude ?? ""} className={field}
                 inputMode="decimal" placeholder="120.9842" />
        </label>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Check-in radius (metres)</span>
          <input name="radius" defaultValue={loc?.self_checkin_radius_m ?? 200} className={field}
                 inputMode="numeric" />
          <span className="mt-1 block text-[12px] text-ink-3">How close they must be. Default 200.</span>
        </label>
        <label className="block">
          <span className="mb-1 block text-[13px] font-medium text-ink">Accuracy cap (metres)</span>
          <input name="accuracy_cap" defaultValue={loc?.self_checkin_accuracy_cap_m ?? 150} className={field}
                 inputMode="numeric" />
          <span className="mt-1 block text-[12px] text-ink-3">A phone vaguer than this is asked to try again. Default 150.</span>
        </label>
      </div>

      <label className="flex items-start gap-2.5">
        <input type="checkbox" name="requires_location" checked={requires}
               onChange={(e) => setRequires(e.target.checked)} className="mt-1" />
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Require a location to check in</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            On, a member has to be at the studio. Off, the phone button and the printed
            code become trust-based — anyone with the link can check in. Off is fine for a
            small studio that would rather not fuss with coordinates.
          </span>
        </span>
      </label>

      <Save />
    </form>
  );
}
