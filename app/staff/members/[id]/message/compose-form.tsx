"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { sendMessage, type ComposeState } from "./actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button className={buttonClass} disabled={pending}>
      {pending ? "Queueing…" : "Send"}
    </button>
  );
}

/**
 * The draft arrives in an editable field and nothing else happens on its own.
 * defaultValue rather than value: this is the owner's text from the first
 * keystroke, not a controlled copy of ours they are allowed to amend.
 */
export default function ComposeForm({
  memberId, memberName, email, subject, body, templateKey, backHref,
}: {
  memberId: string;
  memberName: string;
  email: string;
  subject: string;
  body: string;
  templateKey: string | null;
  backHref: string;
}) {
  const [state, action] = useFormState<ComposeState, FormData>(sendMessage, null);

  return (
    <form action={action} className="max-w-[68ch] space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      <input type="hidden" name="member_id" value={memberId} />
      <input type="hidden" name="template_key" value={templateKey ?? ""} />

      <p className="text-[13px] leading-[20px] text-ink-2">
        To {memberName} at <span className="text-ink">{email}</span>
      </p>

      <Field label="Subject">
        <input name="subject" defaultValue={subject} required className={inputClass} />
      </Field>

      <Field
        label="Message"
        hint="This is a draft. Change anything you like — what you send is what is in this box."
      >
        <textarea
          name="body"
          defaultValue={body}
          rows={14}
          required
          className={`${inputClass} resize-y leading-[22px]`}
        />
      </Field>

      <div className="flex items-center gap-4">
        <Submit />
        <Link href={backHref} className="text-[13px] leading-[18px] text-ink-2 underline underline-offset-4 hover:text-ink">
          Cancel
        </Link>
      </div>
    </form>
  );
}
