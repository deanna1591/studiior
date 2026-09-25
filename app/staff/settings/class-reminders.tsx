"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import { saveClassReminders, type PlainState } from "./actions";

function Save() {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}

/**
 * Decision 39 — the schedule pushed to instructors: their week on Sunday
 * evening, and a reminder the evening before each day. Only reaches instructors
 * with a login; published months only. Off by default.
 */
export default function ClassRemindersPanel({ enabled }: { enabled: boolean }) {
  const [state, action] = useFormState<PlainState, FormData>(saveClassReminders, null);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <label className="flex items-start gap-2.5">
          <input type="checkbox" name="instructor_class_reminders" defaultChecked={enabled} className="mt-1" />
          <span className="text-[13px] leading-[19px] text-ink">
            <span className="font-medium">Email instructors their upcoming classes</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              A "your classes this week" digest on Sunday evening, and a reminder the
              evening before each day with tomorrow&rsquo;s classes. Only reaches an
              instructor with a login, and only published months. Off by default.
            </span>
          </span>
        </label>
        <div className="mt-3"><Save /></div>
      </div>
    </form>
  );
}
