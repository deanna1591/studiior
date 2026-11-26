"use client";

import { useState, useTransition } from "react";
import { formatMoney } from "@/lib/format-money";
import type { CodePreview } from "@/lib/discount-code";

/**
 * Decision 120: "Have a code?" A link opens a field with Apply; the price line
 * shows "Code {code}: -{amount}" and the refusal sentence sits under the field.
 * The applied code travels in a hidden input named `name` inside the parent
 * form, and onChange tells the parent the new price.
 */
export default function CodeBox({
  preview, currency, name = "code", onChange, compact = false,
}: {
  preview: (code: string) => Promise<CodePreview>;
  currency: string;
  name?: string | null;
  onChange?: (p: CodePreview | null) => void;
  compact?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [res, setRes] = useState<CodePreview | null>(null);
  const [pending, start] = useTransition();

  function apply() {
    const code = text.trim();
    if (!code) return;
    start(async () => {
      const r = await preview(code);
      setRes(r);
      onChange?.(r.ok && r.applied ? r : null);
    });
  }
  function clear() {
    setRes(null); setText(""); onChange?.(null);
  }

  const applied = res?.ok && res.applied ? res : null;

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
              className={`${compact ? "text-[13px]" : "m-sub"} text-ink underline underline-offset-4`}>
        Have a code?
      </button>
    );
  }
  return (
    <div className={compact ? "" : "mt-1"}>
      {applied && name && <input type="hidden" name={name} value={applied.code ?? ""} />}
      <div className="flex gap-2">
        <input value={text} onChange={(e) => { setText(e.target.value); if (res) { setRes(null); onChange?.(null); } }}
               onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); apply(); } }}
               placeholder="Code" autoCapitalize="characters" autoComplete="off" spellCheck={false}
               aria-label="Discount code"
               className="min-w-0 flex-1 rounded-xl border border-line bg-surface px-3 py-2.5 text-[15px] uppercase text-ink" />
        {applied ? (
          <button type="button" onClick={clear}
                  className="m-press shrink-0 rounded-xl px-4 text-[14px] font-semibold text-ink"
                  style={{ background: "var(--accent-chip)" }}>Remove</button>
        ) : (
          <button type="button" onClick={apply} disabled={pending || !text.trim()}
                  className="m-press shrink-0 rounded-xl px-4 text-[14px] font-semibold text-ink disabled:opacity-60"
                  style={{ background: "var(--accent-chip)" }}>{pending ? "Checking…" : "Apply"}</button>
        )}
      </div>
      {applied && (
        <p className="m-sub mt-2 flex items-baseline justify-between gap-3 text-ink">
          <span>Code {applied.code}</span>
          <span className="num">-{formatMoney(applied.discountCents, applied.currency ?? currency)}</span>
        </p>
      )}
      {res && !applied && res.message && (
        <p className={`m-sub mt-2 ${res.ok ? "text-ink-2" : "font-semibold text-ink"}`} role={res.ok ? undefined : "alert"}>{res.message}</p>
      )}
    </div>
  );
}
