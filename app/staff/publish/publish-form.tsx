"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { publishMonth, type PublishState } from "./actions";

function Button({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Publishing…" : label}</button>;
}

/**
 * The one button. The warning above it is not a confirm dialog: the holes are
 * on the screen in the preview beside it, and a studio that has read "3 with
 * nobody teaching" and presses anyway has decided. Decision 17 handles what
 * they become.
 */
export default function PublishForm({ month, label, openShifts, unreachable }: {
  month: string; label: string; openShifts: number; unreachable: string[];
}) {
  const [state, action] = useFormState<PublishState, FormData>(publishMonth, null);
  return (
    <form action={action} className="mt-4">
      {state && <Notice kind="error">{state.message}</Notice>}
      {openShifts > 0 && (
        <p className="mb-3 max-w-[60ch] border-l-[3px] bg-amber-tint px-3 py-2 text-[13px] leading-[19px] text-ink"
           style={{ borderLeftColor: "var(--amber-deep)" }}>
          <span className="font-medium">
            {openShifts} {openShifts === 1 ? "class has" : "classes have"} nobody teaching yet.
          </span>{" "}
          You can publish with holes — they become open shifts instructors can apply for — but
          members will be able to book them.
        </p>
      )}
      {unreachable.length > 0 && (
        <p className="mb-3 max-w-[60ch] text-[12px] leading-[18px] text-ink-2">
          {unreachable.join(", ")} {unreachable.length === 1 ? "has" : "have"} no login, so
          publishing cannot email them — you will have to tell them yourself.
        </p>
      )}
      <input type="hidden" name="month" value={month} />
      <Button label={`Publish ${label}`} />
      <p className="mt-2 text-[12px] leading-[18px] text-ink-3">
        This cannot be taken back. Members can book it from the moment you press.
      </p>
    </form>
  );
}
