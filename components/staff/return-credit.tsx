"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { returnCredit } from "@/app/staff/roster/actions";

/**
 * Decision 36(a) — the "Cancel booking" sheet's second state, on a booking that
 * is already late_cancelled. The booking stays cancelled; this returns what the
 * late cancel took (the credit, or the free first class) and clears the strike.
 * A paid drop-in has nothing to return: the button is disabled and says so.
 * Already returned: a quiet line, no button.
 */
export default function ReturnCredit({
  bookingId, firstName, seatKind, returnedAt, returnedBy, timeZone, indent = true,
}: {
  bookingId: string; firstName: string; seatKind: string | null;
  returnedAt: string | null; returnedBy: string | null; timeZone: string; indent?: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const pad = indent ? "ml-9" : "";

  if (returnedAt) {
    const on = new Intl.DateTimeFormat("en-GB", { timeZone, day: "numeric", month: "short", year: "numeric" })
      .format(new Date(returnedAt));
    return <p className={`mt-1 ${pad} text-[12px] text-ink-2`}>Returned on {on} by {returnedBy ?? "the studio"}.</p>;
  }
  if (seatKind === "paid_drop_in") {
    return (
      <div className={`mt-1 ${pad}`}>
        <button disabled className="rounded-lg border border-line-2 px-2.5 py-1 text-[12px] text-ink-2 opacity-60">
          Return credit
        </button>
        <p className="mt-1 max-w-[46ch] text-[12px] leading-[17px] text-ink-2">
          Nothing to return: this seat was paid as a drop-in. Refunds are under Payments.
        </p>
      </div>
    );
  }
  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
        className={`mt-1 ${pad} rounded-lg border border-line-2 px-2.5 py-1 text-[12px] text-ink-2 hover:text-ink`}>
        Return credit
      </button>
    );
  }

  return (
    <div className={`mt-1 ${pad} max-w-[46ch] rounded-lg border border-line bg-surface p-3`}>
      <p className="text-[12.5px] leading-[18px] text-ink">{firstName} cancelled late. The booking stays cancelled.</p>
      <label className="mt-2 flex items-center gap-2 text-[12.5px] text-ink-2">
        <input type="checkbox" checked readOnly />
        Return their credit or free class
      </label>
      <p className="mt-1 text-[12px] leading-[17px] text-ink-2">
        The reservation fee is not affected. Refunds are under Payments.
      </p>
      <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Note (optional)"
        className="mt-2 w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink" />
      {err && <p className="mt-2 text-[12px] text-ink" style={{ color: "var(--coral-deep)" }}>{err}</p>}
      <div className="mt-2 flex items-center gap-2">
        <button disabled={pending}
          onClick={() => start(async () => {
            setErr(null);
            const fd = new FormData();
            fd.set("booking_id", bookingId);
            fd.set("note", note);
            const r = await returnCredit(null, fd);
            if (r?.ok) {
              window.dispatchEvent(new CustomEvent("studiior:toast", { detail: r.message }));
              setOpen(false);
              router.refresh();
            } else {
              setErr(r?.message ?? "That could not be done.");
            }
          })}
          className="rounded-lg px-3 py-1.5 text-[12.5px] font-medium disabled:opacity-50"
          style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
          {pending ? "Returning…" : "Return credit"}
        </button>
        <button onClick={() => { setOpen(false); setErr(null); }}
          className="text-[12px] text-ink-2 underline underline-offset-4">Close</button>
      </div>
    </div>
  );
}
