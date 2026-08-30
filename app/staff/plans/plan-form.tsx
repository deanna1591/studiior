"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import Link from "next/link";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import {
  FIELDS, PLAN_TYPE_HINT, PLAN_TYPE_LABEL, VISIBILITY_LABEL,
  fromCents, type PlanType,
} from "@/lib/plans";
import { createPlan, updatePlan, type PlanFormState } from "./actions";

export type PlanDraft = {
  id?: string;
  name: string;
  description: string | null;
  type: PlanType;
  price_cents: number | null;
  visibility: string;
  status: string;
  signup_fee_cents: number;
  billing_interval: string | null;
  billing_interval_count: number;
  credits: number | null;
  credits_per_period: number | null;
  validity_days: number | null;
  commitment_months: number;
  cancellation_notice_days: number;
  freeze_allowed: boolean;
  max_freeze_days: number | null;
  booking_window_days: number | null;
  max_bookings_per_day: number | null;
  restrictions: { class_type_ids?: string[] } | null;
};

function Section({ title, note, children }: { title: string; note?: string; children: React.ReactNode }) {
  return (
    <section className="rounded border border-stone-200 bg-white p-4">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-stone-500">{title}</h2>
      {note && <p className="mt-1 text-xs text-stone-500">{note}</p>}
      <div className="mt-3 space-y-4">{children}</div>
    </section>
  );
}

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

const num = (v: number | null | undefined) => (v === null || v === undefined ? "" : String(v));

export default function PlanForm({
  draft, classTypes, currency, activeMemberships, mode,
}: {
  draft: PlanDraft;
  classTypes: { id: string; name: string }[];
  currency: string;
  activeMemberships: number;
  mode: "create" | "edit";
}) {
  const [state, action] = useFormState<PlanFormState, FormData>(
    mode === "create" ? createPlan : updatePlan,
    null,
  );
  const [type, setType] = useState<PlanType>(draft.type);
  const f = FIELDS[type];
  const selected = new Set(draft.restrictions?.class_type_ids ?? []);

  return (
    <form action={action} className="max-w-2xl space-y-4">
      {state && <Notice kind="error">{state.error}</Notice>}
      {draft.id && <input type="hidden" name="id" value={draft.id} />}
      <input type="hidden" name="status" value={draft.status} />

      {mode === "edit" && (
        <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2.5 text-sm text-amber-900">
          <p className="font-medium">
            {activeMemberships === 0
              ? "No members are on this plan."
              : `${activeMemberships} member${activeMemberships === 1 ? " is" : "s are"} on this plan.`}
          </p>
          <p className="mt-1 text-[13px] leading-relaxed">
            Editing does <strong>not</strong> reprice them. Each membership snapshots
            its price when it is bought (§7.1), so a change here only affects
            people who buy from now on. The same goes for credits, validity and
            commitment terms: existing members keep what they signed up to.
            {" "}What <em>does</em> apply immediately to everyone on this plan are the
            booking overrides — window and daily limit — because those are read
            live at booking time.
          </p>
        </div>
      )}

      <Section title="Identity">
        <Field label="Name">
          <input name="name" required defaultValue={draft.name} className={inputClass}
                 placeholder="Unlimited Monthly" />
        </Field>
        <Field label="Description">
          <textarea name="description" rows={2} defaultValue={draft.description ?? ""}
                    className={inputClass} placeholder="What a member is buying." />
        </Field>
        <Field label="Type">
          <select name="type" value={type} className={inputClass}
                  onChange={(e) => setType(e.target.value as PlanType)}>
            {(Object.keys(PLAN_TYPE_LABEL) as PlanType[]).map((t) => (
              <option key={t} value={t}>{PLAN_TYPE_LABEL[t]}</option>
            ))}
          </select>
          <p className="mt-1 text-xs text-stone-500">{PLAN_TYPE_HINT[type]}</p>
        </Field>
        <Field label="Visibility">
          <select name="visibility" defaultValue={draft.visibility} className={inputClass}>
            {Object.entries(VISIBILITY_LABEL).map(([v, label]) => (
              <option key={v} value={v}>{label}</option>
            ))}
          </select>
        </Field>
      </Section>

      <Section title="Money" note={`All amounts in ${currency}, the studio's currency.`}>
        <div className="grid grid-cols-2 gap-3">
          <Field label={`Price (${currency})`}>
            <input name="price" required inputMode="decimal"
                   defaultValue={draft.price_cents === null ? "" : fromCents(draft.price_cents)}
                   className={inputClass} placeholder="2800.00" />
          </Field>
          <Field label={`Signup fee (${currency})`}>
            <input name="signup_fee" inputMode="decimal"
                   defaultValue={fromCents(draft.signup_fee_cents)} className={inputClass} />
          </Field>
        </div>
        {f.billing ? (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Bills every">
              <input name="billing_interval_count" type="number" min={1}
                     defaultValue={draft.billing_interval_count} className={inputClass} />
            </Field>
            <Field label="Interval">
              <select name="billing_interval" defaultValue={draft.billing_interval ?? "month"}
                      className={inputClass}>
                <option value="week">week(s)</option>
                <option value="month">month(s)</option>
                <option value="quarter">quarter(s)</option>
                <option value="year">year(s)</option>
              </select>
            </Field>
          </div>
        ) : (
          <p className="text-xs text-stone-500">
            A {PLAN_TYPE_LABEL[type].toLowerCase()} is bought once, so there is no billing schedule.
          </p>
        )}
      </Section>

      <Section title="What it buys">
        {f.creditsPerPeriod && (
          <Field label="Classes per period">
            <input name="credits_per_period" type="number" min={0}
                   defaultValue={num(draft.credits_per_period)} className={inputClass}
                   placeholder="Leave empty for unlimited" />
            <p className="mt-1 text-xs text-stone-500">
              Empty means unlimited. An allowance resets each billing period and does
              not roll over (Decision 3).
            </p>
          </Field>
        )}
        {f.credits && (
          <Field label="Classes included">
            <input name="credits" type="number" min={1} defaultValue={num(draft.credits)}
                   className={inputClass} placeholder="10" />
          </Field>
        )}
        {f.validity && (
          <Field label="Valid for (days)">
            <input name="validity_days" type="number" min={1} defaultValue={num(draft.validity_days)}
                   className={inputClass} placeholder="180" />
            <p className="mt-1 text-xs text-stone-500">
              Counted from purchase. A credit cannot be spent past its expiry (§6).
            </p>
          </Field>
        )}
        <fieldset>
          <legend className="mb-1 block text-sm font-medium text-stone-700">
            Class types this plan covers
          </legend>
          <p className="mb-2 text-xs text-stone-500">
            None selected means every class type. Otherwise booking a class outside
            the list is refused with <code>class_type_not_in_plan</code> (§2.1.9).
          </p>
          <div className="space-y-1.5">
            {classTypes.map((ct) => (
              <label key={ct.id} className="flex items-center gap-2 text-sm">
                <input type="checkbox" name="class_type_ids" value={ct.id}
                       defaultChecked={selected.has(ct.id)} />
                {ct.name}
              </label>
            ))}
            {classTypes.length === 0 && (
              <p className="text-sm text-stone-400">No class types yet.</p>
            )}
          </div>
        </fieldset>
      </Section>

      <Section
        title="Commitment"
        note={f.commitment ? undefined : `Commitment and freeze terms apply to recurring plans. A ${PLAN_TYPE_LABEL[type].toLowerCase()} has none.`}
      >
        {f.commitment && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Minimum commitment (months)">
              <input name="commitment_months" type="number" min={0}
                     defaultValue={draft.commitment_months} className={inputClass} />
            </Field>
            <Field label="Cancellation notice (days)">
              <input name="cancellation_notice_days" type="number" min={0}
                     defaultValue={draft.cancellation_notice_days} className={inputClass} />
            </Field>
          </div>
        )}
        {f.freeze && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Freezing">
              <label className="flex items-center gap-2 pt-2 text-sm">
                <input type="checkbox" name="freeze_allowed" defaultChecked={draft.freeze_allowed} />
                Members may request a freeze
              </label>
            </Field>
            <Field label="Max freeze days (total)">
              <input name="max_freeze_days" type="number" min={0}
                     defaultValue={num(draft.max_freeze_days)} className={inputClass}
                     placeholder="No cap" />
            </Field>
          </div>
        )}
        <div className="grid grid-cols-2 gap-3">
          <Field label="Booking window (days)">
            <input name="booking_window_days" type="number" min={0}
                   defaultValue={num(draft.booking_window_days)} className={inputClass}
                   placeholder="Studio default" />
          </Field>
          <Field label="Max bookings per day">
            <input name="max_bookings_per_day" type="number" min={0}
                   defaultValue={num(draft.max_bookings_per_day)} className={inputClass}
                   placeholder="Studio default" />
          </Field>
        </div>
        <p className="text-xs text-stone-500">
          Both override the studio setting for members on this plan, and unlike price
          they take effect immediately for everyone.
        </p>
      </Section>

      <div className="flex items-center gap-4">
        <Submit label={mode === "create" ? "Create plan" : "Save changes"} />
        <Link href="/plans" className="text-sm text-stone-600 underline underline-offset-4">
          Cancel
        </Link>
      </div>
    </form>
  );
}
