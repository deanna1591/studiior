"use client";

import { useState, useTransition } from "react";
import { exportMembers } from "@/app/staff/members/actions";
import { membersCsv, exportFilename } from "@/lib/members-csv";

/**
 * Decision 109: Export button (owner/manager; the RPC is the boundary). The CSV
 * is built in the browser from the RPC result so a large studio is one request,
 * not a streamed file, and phone and dates stay text.
 */
export default function MembersExport({
  slug, q, filter, sort,
}: { slug: string; q: string; filter: string; sort: string }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  return (
    <div className="flex flex-col items-end gap-0.5">
      <button
        disabled={pending}
        onClick={() => start(async () => {
          setErr(null);
          const r = await exportMembers(q, filter, sort);
          if (!r.ok) { setErr(r.error); return; }
          const blob = new Blob([membersCsv(r.rows)], { type: "text/csv;charset=utf-8" });
          const url = URL.createObjectURL(blob);
          const a = document.createElement("a");
          a.href = url; a.download = exportFilename(slug, new Date());
          document.body.appendChild(a); a.click(); a.remove();
          URL.revokeObjectURL(url);
        })}
        className="rounded-full border border-line-2 bg-surface px-4 py-2 text-[13px] font-semibold text-ink disabled:opacity-60">
        {pending ? "Preparing…" : "Export CSV"}
      </button>
      <span className="max-w-[18rem] text-right text-[11px] leading-[14px] text-ink-3">
        Members marked no in the marketing column have unsubscribed or never opted in. Do not send them marketing.
      </span>
      {err && <span className="text-[11px] text-ink-2">{err}</span>}
    </div>
  );
}
