"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { accentSolid } from "@/lib/accent-pair";
import { buyPlanAsGuest, previewGuestCode, type GuestBuyState } from "./guest-actions";
import CodeBox from "@/components/code-box";
import { formatMoney } from "@/lib/format-money";
import type { CodePreview } from "@/lib/discount-code";

/**
 * Decision 118: name, email and mobile, then "Continue to pay" opens the Xendit
 * checkout. No account needed; the plan waits under the email until the buyer
 * sets one up (or lands in their account at once if they already have one).
 */
export default function GuestBuyForm({ planId, loginHref, currency = "PHP" }: { planId: string; loginHref: string; currency?: string }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [code, setCode] = useState<CodePreview | null>(null);

  function submit(fd: FormData) {
    setErr(null);
    fd.set("plan_id", planId);
    start(async () => {
      const r: GuestBuyState = await buyPlanAsGuest(null, fd);
      if (r?.ok && r.url) { window.location.assign(r.url); return; }
      setErr(r?.message ?? "That didn't work. Please try again.");
    });
  }

  return (
    <form action={submit} className="space-y-4">
      <Field name="name" label="Your name" placeholder="Your full name" autoComplete="name" />
      <Field name="email" label="Email" type="email" placeholder="you@example.com" autoComplete="email"
             hint="Your receipt and the link to set up your account go here." />
      <Field name="phone" label="Mobile number" type="tel" placeholder="0917 123 4567" autoComplete="tel"
             hint="We call or text you about your classes." />

      {/* Decision 120: a discount code. The email, when filled in, lets a shared
          code count once per person. */}
      <CodeBox currency={currency} onChange={setCode}
               preview={(c) => previewGuestCode({ planId, code: c,
                 email: (document.getElementById("g-email") as HTMLInputElement | null)?.value })} />
      {code?.priceCents != null && (
        <p className="m-body flex items-baseline justify-between text-ink">
          <span className="font-semibold">{code.priceCents === 0 ? "Total" : "You pay"}</span>
          <span className="num font-semibold">{formatMoney(code.priceCents, code.currency ?? currency)}</span>
        </p>
      )}

      {err && (
        <p className="rounded-lg px-3 py-2 text-[13px] leading-[19px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}

      <button type="submit" disabled={pending}
        className="m-press w-full rounded-full py-3.5 text-center text-[16px] font-semibold disabled:opacity-60"
        style={accentSolid()}>
        {pending ? (code?.priceCents === 0 ? "One moment…" : "Opening checkout…") : code?.priceCents === 0 ? "Complete" : "Continue to pay"}
      </button>
      <p className="m-micro text-center text-ink-3">Card or GCash, on the next screen.</p>
      <p className="m-sub text-center text-ink-2">
        Already have an account?{" "}
        <Link href={loginHref} className="text-ink underline underline-offset-4">Sign in</Link>
      </p>
    </form>
  );
}

function Field({ name, label, placeholder, type = "text", hint, autoComplete }: {
  name: string; label: string; placeholder?: string; type?: string; hint?: string; autoComplete?: string;
}) {
  return (
    <div>
      <label className="m-label mb-1 block text-ink" htmlFor={`g-${name}`}>{label}</label>
      <input id={`g-${name}`} name={name} type={type} placeholder={placeholder} required autoComplete={autoComplete}
        className="w-full rounded-xl border border-line bg-surface px-3.5 py-2.5 text-[15px] text-ink" />
      {hint && <p className="m-micro mt-1 text-ink-3">{hint}</p>}
    </div>
  );
}
