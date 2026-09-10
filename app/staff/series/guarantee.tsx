"use client";

import Link from "next/link";
import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { setSeriesTier, type LifecycleState } from "./lifecycle-actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

const COPY = {
  core:   "Runs if it reaches its minimum by the cutoff. If it does not, it does not run and the instructor is paid a holding rate.",
  flex:   "Runs only if it reaches its minimum. If it does not there is no obligation and, unless the studio sets one, no pay.",
  always: "Runs whatever the numbers are, and is never cancelled for them.",
} as const;

/**
 * Where a studio actually sets a tier: per slot, on the series.
 *
 * NOT DRAWN AT ALL when neither switch is on. A tier control on a studio that
 * has not turned guarantees on is a control that changes a column nothing reads
 * — the decorative control this build refuses, and worse here than elsewhere
 * because it would look like it had done something.
 */
export default function SeriesGuarantee({
  id, tier, minBookings, coreEnabled, flexEnabled,
}: {
  id: string; tier: "core" | "flex" | "always";
  minBookings: number | null; coreEnabled: boolean; flexEnabled: boolean;
}) {
  const [state, action] = useFormState<LifecycleState, FormData>(setSeriesTier, null);
  const [picked, setPicked] = useState(tier);

  if (!coreEnabled && !flexEnabled) {
    return (
      <section className="mt-8 border-t border-line pt-5">
        <p className="m-sub max-w-[62ch] text-ink-2">
          Every class in this series runs whatever the numbers are. To let a class
          depend on how many people book it, turn guarantees on in{" "}
          <Link href="/settings" className="text-lime-text underline underline-offset-4">
            settings
          </Link>{" "}
          — it is off until you do.
        </p>
      </section>
    );
  }

  return (
    <section className="mt-8 border-t border-line pt-5">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <form action={action} className="max-w-2xl">
        <input type="hidden" name="id" value={id} />
        <p className="mb-2 text-[13px] font-medium leading-[19px] text-ink">
          Does this class run when few people book it?
        </p>
        <div className="flex flex-wrap gap-1.5">
          {(["core", "flex", "always"] as const).map((t) => {
            const off = (t === "core" && !coreEnabled) || (t === "flex" && !flexEnabled);
            const on = picked === t;
            return (
              <label key={t}
                     className={`m-tap cursor-pointer rounded-lg border px-3 py-1.5 text-[13px]
                                 font-medium ${off ? "cursor-not-allowed opacity-45" : ""}`}
                     style={on
                       ? { borderColor: "var(--ink)", color: "var(--ink)" }
                       : { borderColor: "var(--line-2)", color: "var(--ink-2)" }}>
                <input type="radio" name="tier" value={t} defaultChecked={on} disabled={off}
                       onChange={() => setPicked(t)} className="sr-only" />
                {t === "core" ? "Core" : t === "flex" ? "Flex" : "Always"}
              </label>
            );
          })}
          {picked !== "always" && (
            <label className="text-[13px] leading-[20px] text-ink-2">
              <span className="sr-only">Minimum bookings</span>
              <input name="min_bookings" type="number" min={0} max={99}
                     defaultValue={minBookings ?? ""} placeholder="min"
                     className={`${inputClass} w-20`} />
            </label>
          )}
          <Save />
        </div>
        <p className="m-micro mt-2 max-w-[62ch] text-ink-3">
          {COPY[picked]}
          {(!coreEnabled || !flexEnabled) && (
            <>
              {" "}
              {!coreEnabled ? "Core" : "Flex"} is switched off for this studio, so
              that option is unavailable until it is turned on in{" "}
              <Link href="/settings" className="underline underline-offset-4">settings</Link>.
            </>
          )}
          {" "}Members are never told a class might not run.
        </p>
      </form>
    </section>
  );
}
