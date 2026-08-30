import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import { TYPE_LABEL, StatusPill } from "./labels";

export const dynamic = "force-dynamic";

export default async function ImportsList() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);

  // Permissions §5: importing is Owner and Manager. Front desk creates members
  // one at a time; bulk import rewrites history, which is a different power.
  // The refusal that counts is imports_manager — this only avoids offering it.
  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="Import" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-stone-600">
          Importing is owners and managers. Your role is {ctx.role.replace("_", " ")}.
        </p>
      </Shell>
    );
  }

  const supabase = createClient();
  const { data: imports } = await supabase
    .from("imports")
    .select("id, type, filename, status, row_count, error_count, report, created_at")
    .order("created_at", { ascending: false })
    .limit(50);

  return (
    <Shell
      title="Import"
      subtitle={`${ctx.studioName} · bring existing members across`}
      right={
        <>
          <NavLink href="/imports/new">New import</NavLink>
          <NavLink href="/">Back to week</NavLink>
        </>
      }
    >
      <p className="mb-6 max-w-2xl text-sm leading-relaxed text-stone-600">
        Import members first, then their memberships, then attendance — each one
        matches on email, so the members have to exist before the rest will land.
        Nothing is written until you have seen the dry run, and any completed
        import can be rolled back.
      </p>

      {(imports ?? []).length === 0 ? (
        <p className="text-sm text-stone-500">
          Nothing imported yet.{" "}
          <Link href="/imports/new" className="underline underline-offset-4">Start one</Link>.
        </p>
      ) : (
        <ul className="divide-y divide-stone-200 rounded border border-stone-200 bg-white">
          {(imports ?? []).map((i) => {
            const r = (i.report ?? {}) as { ok?: number; skip?: number; error?: number };
            return (
              <li key={i.id}>
                <Link href={`/imports/${i.id}`}
                      className="flex items-center justify-between gap-4 px-3 py-3 hover:bg-stone-50">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium">{i.filename}</div>
                    <div className="text-xs text-stone-500">
                      {TYPE_LABEL[i.type] ?? i.type} · {i.row_count} row{i.row_count === 1 ? "" : "s"}
                      {i.status === "dry_run_complete" && r.error !== undefined &&
                        ` · ${r.ok ?? 0} ready, ${r.skip ?? 0} skipped, ${r.error ?? 0} with problems`}
                    </div>
                  </div>
                  <StatusPill status={i.status} />
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </Shell>
  );
}
