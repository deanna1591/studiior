"use client";

import Link from "next/link";
import { useFormState, useFormStatus } from "react-dom";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import { createMember, type MemberState } from "../actions";

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Adding…" : "Add member"}</button>;
}

/**
 * A walk-in signing up at the counter, which is the whole reason this exists:
 * every member before now arrived through the importer or the demo generator.
 * Permissions §5 gives create to front desk as well as managers, so this screen
 * is not manager-gated.
 */
export default function NewMemberForm() {
  const [state, action] = useFormState<MemberState, FormData>(createMember, null);
  return (
    <form action={action} className="max-w-xl space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}

      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="First name">
          <input name="first_name" required className={inputClass} autoComplete="given-name" />
        </Field>
        <Field label="Last name">
          <input name="last_name" required className={inputClass} autoComplete="family-name" />
        </Field>
      </div>

      <Field label="Goes by" hint="Optional. What you would call them at the door, if it is not their first name.">
        <input name="preferred_name" className={inputClass} />
      </Field>

      <Field label="Email">
        <input name="email" type="email" required className={inputClass} autoComplete="email" />
        <p className="mt-1 text-xs text-ink-3">
          How they get their account, their booking confirmations and their receipts.
          Without one they can be a member here but cannot sign in.
        </p>
      </Field>

      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Phone">
          {/* Not mono: a phone number in a monospace face reads as a part code. */}
          <input name="phone" type="tel" className={inputClass} autoComplete="tel" />
        </Field>
        <Field label="Date of birth" hint="Optional, and only where a class has an age rule.">
          <input name="date_of_birth" type="date" className={inputClass} />
        </Field>
      </div>

      <fieldset className="rounded-xl border border-line bg-paper p-3.5">
        <legend className="px-1 text-[12px] font-medium uppercase leading-4 tracking-[0.06em] text-ink-3">
          Emergency contact
        </legend>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Name"><input name="ec_name" className={inputClass} /></Field>
          <Field label="Phone"><input name="ec_phone" type="tel" className={inputClass} /></Field>
          <Field label="Relationship"><input name="ec_relationship" className={inputClass} placeholder="Partner" /></Field>
        </div>
        <p className="mt-2 text-xs text-ink-3">
          Reformer work carries injury risk and this is the number the studio rings.
          It appears on the roster for the people teaching them.
        </p>
      </fieldset>

      <fieldset className="rounded-xl border border-line bg-paper p-3.5">
        <legend className="px-1 text-[12px] font-medium uppercase leading-4 tracking-[0.06em] text-ink-3">
          Address
        </legend>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Street"><input name="line1" className={inputClass} /></Field>
          <Field label="City"><input name="city" className={inputClass} /></Field>
          <Field label="Postcode"><input name="postal_code" className={inputClass} /></Field>
        </div>
      </fieldset>

      {/* Unticked by default and it stays that way. Consent is a positive act,
          and a pre-ticked box opts a walk-in into mail they never agreed to. */}
      <label className="flex items-start gap-2.5">
        <input type="checkbox" name="marketing_opt_in" className="mt-0.5 h-4 w-4" />
        <span className="text-[13px] leading-[19px] text-ink-2">
          They agreed to hear about offers and studio news. Leave this unticked
          unless they said yes — their class emails and receipts arrive either way.
        </span>
      </label>

      <div className="flex items-center gap-4">
        <Submit />
        <Link href="/members" className="text-sm text-ink-2 underline underline-offset-4">Cancel</Link>
      </div>
    </form>
  );
}
