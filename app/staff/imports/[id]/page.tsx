import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { FIELDS } from "@/lib/csv";
import { TYPE_LABEL, StatusPill } from "../labels";
import MappingForm from "./mapping-form";
import { CommitButton, RollbackButton } from "./run-buttons";

export const dynamic = "force-dynamic";

const NOUN: Record<string, string> = {
  members: "members",
  memberships: "memberships",
  attendance: "visits",
};

export default async function ImportDetail({ params }: { params: { id: string } }) {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);

  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="Import" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-ink-2">Importing is owners and managers.</p>
      </Shell>
    );
  }

  const supabase = createClient();
  const { data: imp } = await supabase
    .from("imports")
    .select("id, type, filename, status, row_count, error_count, report, mapping, created_at")
    .eq("id", params.id)
    .maybeSingle();
  if (!imp) notFound();

  const { data: rows } = await supabase
    .from("import_rows")
    .select("id, row_number, raw, normalized, status, error")
    .eq("import_id", imp.id)
    .order("row_number")
    .limit(500);

  const mapping = (imp.mapping ?? {}) as {
    headers?: string[];
    guessed?: Record<string, string>;
    applied?: Record<string, string>;
  };
  const headers = mapping.headers ?? [];
  const chosen = mapping.applied ?? mapping.guessed ?? {};
  const fields = FIELDS[imp.type] ?? [];
  const sample = (rows?.[0]?.raw ?? {}) as Record<string, string>;

  const counts = { ok: 0, skip: 0, error: 0, committed: 0, rolled_back: 0, pending: 0 } as Record<string, number>;
  for (const r of rows ?? []) counts[r.status] = (counts[r.status] ?? 0) + 1;

  const done = imp.status === "complete";
  const rolledBack = imp.status === "rolled_back";
  const reviewed = imp.status === "dry_run_complete";
  const problems = (rows ?? []).filter((r) => r.status === "error" || r.status === "skip");

  return (
    <Shell
      title={imp.filename}
      subtitle={`${TYPE_LABEL[imp.type] ?? imp.type} · ${imp.row_count} row${imp.row_count === 1 ? "" : "s"}`}
      right={
        <>
          <NavLink href="/imports">All imports</NavLink>
          <NavLink href="/">Back to week</NavLink>
        </>
      }
    >
      <div className="mb-6"><StatusPill status={imp.status} /></div>

      {/* ---- step 1: mapping. Editable until it has actually been imported. ---- */}
      {!done && !rolledBack && (
        <section className="mb-8">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-3">
            Match your columns
          </h2>
          <MappingForm
            id={imp.id}
            fields={fields}
            headers={headers}
            mapping={chosen}
            sample={sample}
            hasRun={reviewed}
          />
        </section>
      )}

      {/* ---- step 2: the review. What would happen, before anything happens. ---- */}
      {reviewed && (
        <section className="mb-8">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-3">
            What this would do
          </h2>
          <div className="mb-4 flex flex-wrap gap-3 text-sm">
            <Tally n={counts.ok ?? 0} label={`ready to import`} tone="ok" />
            <Tally n={counts.skip ?? 0} label="already here, will be left alone" tone="skip" />
            <Tally n={counts.error ?? 0} label="cannot be imported" tone="error" />
          </div>

          {(counts.error ?? 0) > 0 && (
            <p className="mb-4 max-w-2xl text-sm text-ink-2">
              Rows with a problem are left out — the rest still import. Fix them
              in your file and upload it again, or import what is ready now and
              deal with the rest afterwards.
            </p>
          )}

          {problems.length > 0 && (
            <div className="mb-4 max-h-96 overflow-auto rounded border border-line bg-white">
              <table className="w-full text-sm">
                <thead className="sticky top-0 border-b border-line bg-paper text-left text-xs uppercase tracking-wide text-ink-3">
                  <tr>
                    <th className="px-3 py-2 font-medium">Row</th>
                    <th className="px-3 py-2 font-medium">Reason</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {problems.map((r) => (
                    <tr key={r.id} className={r.status === "error" ? "" : "text-ink-3"}>
                      <td className="whitespace-nowrap px-3 py-2 tabular-nums">{r.row_number}</td>
                      <td className="px-3 py-2">{r.error}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {(counts.ok ?? 0) > 0 ? (
            <CommitButton id={imp.id} okCount={counts.ok ?? 0} />
          ) : (
            <p className="text-sm text-ink-2">
              Nothing here would be imported. Change the mapping above, or fix
              the file and start again.
            </p>
          )}
        </section>
      )}

      {/* ---- step 3: done, and undoable. ---- */}
      {done && (
        <section className="space-y-4">
          <p className="text-sm text-ink">
            {counts.committed ?? 0} {NOUN[imp.type] ?? "rows"} imported
            {(counts.skip ?? 0) > 0 && `, ${counts.skip} skipped as already here`}
            {(counts.error ?? 0) > 0 && `, ${counts.error} left out`}.
            {imp.type === "attendance" &&
              " Visit counts, last-visit dates and health bands have been recalculated for everyone in the file."}
          </p>
          <p className="text-sm">
            <Link href="/" className="underline underline-offset-4">Back to the week</Link>
          </p>
          <RollbackButton id={imp.id} created={counts.committed ?? 0} noun={NOUN[imp.type] ?? "rows"} />
        </section>
      )}

      {rolledBack && (
        <p className="max-w-2xl text-sm text-ink-2">
          This import was undone. Everything it created has been removed; the
          file and the row-by-row record are kept so you can see what happened.
          Upload the file again to redo it.
        </p>
      )}
    </Shell>
  );
}

function Tally({ n, label, tone }: { n: number; label: string; tone: "ok" | "skip" | "error" }) {
  const cls = {
    ok: "border-lime-text bg-lime-tint text-ink",
    skip: "border-line bg-paper text-ink-2",
    error: "border-coral bg-coral-tint text-ink",
  }[tone];
  return (
    <span className={`rounded border px-3 py-1.5 ${cls}`}>
      <span className="font-semibold tabular-nums">{n}</span> {label}
    </span>
  );
}
