"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { removeBooking } from "@/app/staff/roster/actions";

/**
 * Decision 92(b) — remove a member from a class. Desk-up. Opens a small sheet:
 * a "Return their credit or free class" tick (on by default), an optional note,
 * and a "Remove" button. On success a page-level toast shows and the row leaves
 * the roster (router.refresh). Tick off is a late cancel inside the cutoff.
 */
export default function RemoveBooking({
  bookingId, firstName,
}: { bookingId: string; firstName: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [ret, setRet] = useState(true);
  const [note, setNote] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();

  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
        className="mt-1 ml-9 rounded-lg border border-line-2 px-2.5 py-1 text-[12px] text-ink-2 hover:text-ink">
        Remove from class
      </button>
    );
  }

  return (
    <div className="mt-1 ml-9 max-w-[42ch] rounded-lg border border-line bg-surface p-3">
      <p className="text-[12.5px] leading-[18px] text-ink">Remove {firstName} from this class?</p>
      <label className="mt-2 flex items-center gap-2 text-[12.5px] text-ink-2">
        <input type="checkbox" checked={ret} onChange={(e) => setRet(e.target.checked)} />
        Return their credit or free class
      </label>
      <p className="mt-1 text-[11.5px] leading-[16px] text-ink-3">
        {ret ? "No penalty. Their credit or free class goes back." : "Counts as a late cancel inside the cut-off."}
      </p>
      <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Note (optional)"
        className="mt-2 w-full rounded-lg border border-line-2 bg-surface px-2.5 py-1.5 text-[12.5px] text-ink" />
      {err && <p className="mt-2 text-[12px]" style={{ color: "var(--coral-deep)" }}>{err}</p>}
      <div className="mt-2 flex items-center gap-2">
        <button disabled={pending}
          onClick={() => start(async () => {
            setErr(null);
            const fd = new FormData();
            fd.set("booking_id", bookingId);
            fd.set("return", ret ? "1" : "0");
            fd.set("note", note);
            const r = await removeBooking(null, fd);
            if (r?.ok) {
              window.dispatchEvent(new CustomEvent("studiior:toast", { detail: r.message }));
              router.refresh();
            } else {
              setErr(r?.message ?? "That could not be done.");
            }
          })}
          className="rounded-lg px-3 py-1.5 text-[12.5px] font-medium text-paper disabled:opacity-50"
          style={{ background: "var(--coral-deep)" }}>
          {pending ? "Removing…" : "Remove"}
        </button>
        <button onClick={() => { setOpen(false); setErr(null); }}
          className="text-[12px] text-ink-2 underline underline-offset-4">Keep booked</button>
      </div>
    </div>
  );
}
