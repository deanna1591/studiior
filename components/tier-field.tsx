"use client";

import { useState } from "react";
import { inputClass } from "@/components/ui";

/**
 * The guarantee-tier control, inline inside a create form (the one-off class
 * form and the calendar's click-to-create). Same shape and copy as the series
 * form's tier control, same condition: NOT DRAWN AT ALL unless the studio has
 * guarantees or flex on — a tier picker at a studio that turned neither on
 * changes a column nothing reads, the decorative control this build refuses.
 *
 * It contributes `tier` and `min_bookings` to the surrounding form. When the
 * control is absent the form sends nothing and the class is created core, which
 * is exactly what happened before this existed.
 *
 * The standalone-flex COST is said here as a heads-up when flex is picked; the
 * database confirms after creation whether the class actually landed standalone
 * (the `standalone_flex` warning), because adjacency depends on what else the
 * instructor teaches that day and can only be known once the class exists.
 */
const COPY = {
  core: "Runs if it reaches its minimum by the cutoff; if it does not, it does not run and the instructor is paid a holding rate.",
  flex: "Runs only if it reaches its minimum. If it does not there is no obligation and, unless the studio sets one, no pay.",
  always: "Runs whatever the numbers are, and is never cancelled for them.",
} as const;

export default function TierField({
  coreEnabled, flexEnabled,
}: { coreEnabled: boolean; flexEnabled: boolean }) {
  const [picked, setPicked] = useState<"core" | "flex" | "always">("core");
  if (!coreEnabled && !flexEnabled) return null;

  return (
    <fieldset className="border-t border-line pt-4">
      <legend className="mb-2 text-[13px] font-medium leading-[19px] text-ink">
        Does this class run when few people book it?
      </legend>
      <div className="flex flex-wrap items-center gap-1.5">
        {(["core", "flex", "always"] as const).map((t) => {
          const off = (t === "core" && !coreEnabled) || (t === "flex" && !flexEnabled);
          const on = picked === t;
          return (
            <label key={t}
                   className={`m-tap cursor-pointer rounded-lg border px-3 py-1.5 text-[13px] font-medium ${off ? "cursor-not-allowed opacity-45" : ""}`}
                   style={on
                     ? { borderColor: "var(--ink)", color: "var(--ink)" }
                     : { borderColor: "var(--line-2)", color: "var(--ink-2)" }}>
              <input type="radio" name="tier" value={t} defaultChecked={t === "core"} disabled={off}
                     onChange={() => setPicked(t)} className="sr-only" />
              {t === "core" ? "Core" : t === "flex" ? "Flex" : "Always"}
            </label>
          );
        })}
        {picked !== "always" && (
          <label className="text-[13px] leading-[20px] text-ink-2">
            <span className="sr-only">Minimum bookings</span>
            <input name="min_bookings" type="number" min={0} max={99} placeholder="min"
                   className={`${inputClass} w-20`} />
          </label>
        )}
      </div>
      <p className="m-micro mt-2 max-w-[62ch] text-ink-3">
        {COPY[picked]}
        {picked === "flex" && (
          <>
            {" "}
            <span className="text-ink-2">A one-off flex class usually has no other class of the same
            instructor beside it, and a standalone flex slot carries a standby fee</span> — you will be
            told after creating it whether this one does.
          </>
        )}
        {" "}Members are never told a class might not run.
      </p>
    </fieldset>
  );
}
