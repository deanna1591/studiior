"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { setMemberPhoneAction } from "@/app/staff/members/book-actions";
import { formatPhone } from "@/lib/phone";

// Decision 100. Desk-up edits a member's phone, with the member sheet's own
// validation (Decision 94). The Decision 98 same-person recheck fires on the
// write (the members_phone_recheck trigger), so there is nothing extra to do.
export default function EditPhone({
  memberId, current,
}: { memberId: string; current: string | null }) {
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [val, setVal] = useState(current ?? "");
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState(false);
  const [pending, start] = useTransition();

  if (!editing) {
    return (
      <span className="inline-flex items-center gap-2">
        <span className="num text-[14px] text-ink">{current ? formatPhone(current) : "No phone on file"}</span>
        <button onClick={() => { setEditing(true); setOk(false); setErr(null); }}
                className="text-[12px] text-lime-text underline">Edit</button>
        {ok && <span className="text-[12px] text-ink-3">Saved</span>}
      </span>
    );
  }

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <input autoFocus value={val} onChange={(e) => setVal(e.target.value)}
             placeholder="Mobile number"
             className="rounded-lg border border-line-2 bg-paper px-3 py-1.5 text-[14px] text-ink" />
      <button disabled={pending}
              onClick={() => start(async () => {
                setErr(null);
                const r = await setMemberPhoneAction(memberId, val);
                if ("error" in r) { setErr(r.error); return; }
                setEditing(false); setOk(true); router.refresh();
              })}
              className="rounded-lg px-3 py-1.5 text-[13px] font-semibold disabled:opacity-60"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        {pending ? "Saving…" : "Save"}
      </button>
      <button onClick={() => { setEditing(false); setVal(current ?? ""); setErr(null); }}
              className="rounded-lg border border-line-2 bg-surface px-3 py-1.5 text-[13px] text-ink">Cancel</button>
      {err && <span className="w-full text-[12px] text-coral-deep">{err}</span>}
    </span>
  );
}
