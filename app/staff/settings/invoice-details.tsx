"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { saveInvoiceDetails, type PlainState } from "./actions";

export type InvoiceDetails = {
  invoice_registered_name: string | null;
  invoice_proprietor: string | null;
  invoice_tin: string | null;
  invoice_address: string | null;
  invoice_email: string | null;
  invoice_landline: string | null;
  invoice_mobile: string | null;
  invoice_atp_no: string | null;
  invoice_atp_date: string | null;
  invoice_series: string | null;
  invoice_vat_rate: number | null;
};

function Buttons({ hasDetails }: { hasDetails: boolean }) {
  const { pending } = useFormStatus();
  return (
    <div className="mt-3 flex gap-2">
      <button name="intent" value="save" className={buttonQuietClass} disabled={pending}>
        {pending ? "Saving…" : "Save"}
      </button>
      {hasDetails && (
        <button name="intent" value="clear" disabled={pending}
                className="rounded border border-line px-3 py-1.5 text-[13px] text-ink-2 disabled:opacity-60">
          Clear (plain receipts)
        </button>
      )}
    </div>
  );
}

function Field({ name, label, value, ph, w = "w-full" }: {
  name: string; label: string; value: string | null; ph?: string; w?: string;
}) {
  return (
    <label className="block text-[12px] leading-[16px] text-ink-2">
      <span className="mb-1 block">{label}</span>
      <input name={name} defaultValue={value ?? ""} placeholder={ph}
             className={`${inputClass} ${w}`} />
    </label>
  );
}

/**
 * Decision 88(c) — a studio's BIR service-invoice details. Filled → a member's
 * payment download is a BIR Service Invoice; left blank → the plain receipt.
 */
export default function InvoiceDetailsPanel({ d }: { d: InvoiceDetails }) {
  const [state, action] = useFormState<PlainState, FormData>(saveInvoiceDetails, null);
  const hasDetails = !!(d.invoice_registered_name && d.invoice_tin);
  return (
    <form action={action} className="max-w-2xl">
      {state && <Notice kind={state.ok ? "ok" : "error"}>{state.message}</Notice>}
      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium leading-[18px] text-ink">Invoice details</p>
        <p className="mt-0.5 text-[12px] leading-[18px] text-ink-3">
          Leave blank to issue plain receipts. When filled, a member downloading a
          paid or refunded payment gets a numbered BIR service invoice.
        </p>

        <div className="mt-3 space-y-2.5">
          <Field name="invoice_registered_name" label="Registered business name"
                 value={d.invoice_registered_name} ph="REFORM COLLECTIVE FITNESS STUDIO" />
          <div className="flex flex-wrap gap-2.5">
            <div className="min-w-[200px] flex-1">
              <Field name="invoice_proprietor" label="Proprietor"
                     value={d.invoice_proprietor} ph="Juan D. Dela Cruz · Prop." />
            </div>
            <div className="min-w-[200px] flex-1">
              <Field name="invoice_tin" label="VAT TIN" value={d.invoice_tin} ph="000-000-000-00000" />
            </div>
          </div>
          <label className="block text-[12px] leading-[16px] text-ink-2">
            <span className="mb-1 block">Registered address (one line each)</span>
            <textarea name="invoice_address" defaultValue={d.invoice_address ?? ""} rows={3}
                      placeholder={"Unit, Building, Street\nBarangay, City\nMetro Manila, Philippines"}
                      className={`${inputClass} w-full`} />
          </label>
          <div className="flex flex-wrap gap-2.5">
            <div className="min-w-[200px] flex-1">
              <Field name="invoice_email" label="Email" value={d.invoice_email} />
            </div>
            <div className="min-w-[120px] flex-1">
              <Field name="invoice_landline" label="Landline" value={d.invoice_landline} />
            </div>
            <div className="min-w-[120px] flex-1">
              <Field name="invoice_mobile" label="Mobile" value={d.invoice_mobile} />
            </div>
          </div>
          <div className="flex flex-wrap gap-2.5">
            <div className="min-w-[160px] flex-1">
              <Field name="invoice_atp_no" label="Acknowledgment Cert. / ATP No." value={d.invoice_atp_no} />
            </div>
            <div className="min-w-[120px] flex-1">
              <Field name="invoice_atp_date" label="Date issued" value={d.invoice_atp_date} ph="2026-01-01" />
            </div>
          </div>
          <div className="flex flex-wrap gap-2.5">
            <div className="min-w-[200px] flex-1">
              <Field name="invoice_series" label="Approved series" value={d.invoice_series} ph="0000001 – 9999999" />
            </div>
            <label className="min-w-[120px] flex-1 text-[12px] leading-[16px] text-ink-2">
              <span className="mb-1 block">VAT rate (%)</span>
              <input name="invoice_vat_rate" type="number" step="0.01" min="0" max="100"
                     defaultValue={d.invoice_vat_rate ?? 12} className={`${inputClass} w-full`} />
            </label>
          </div>
        </div>

        <Buttons hasDetails={hasDetails} />
      </div>
    </form>
  );
}
