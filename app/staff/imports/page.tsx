import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, NavLink, Rows } from "@/components/ui";
import { TYPE_LABEL, StatusPill } from "./labels";

export const dynamic = "force-dynamic";

export default async function ImportsList() {
  const screen = await staffScreen("/imports");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  // Permissions §5: importing is Owner and Manager. Front desk creates members
  // one at a time; bulk import rewrites history, which is a different power.
  // The refusal that counts is imports_manager — this only avoids offering it.
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Import"><Denied what="Importing" role={ctx.role} /></AppShell>;
  }

  const { data: imports } = await supabase
    .from("imports")
    .select("id, type, filename, status, row_count, error_count, report, created_at")
    .order("created_at", { ascending: false })
    .limit(50);

  return (
    <AppShell
      {...shell}
      title="Import"
      actions={
        <Link
          href="/imports/new"
          className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2"
        >
          New import
        </Link>
      }
    >
      <p className="mb-5 max-w-[62ch] text-[13px] leading-[20px] text-ink-2">
        Import members first, then their memberships, then attendance — each one
        matches on email, so the members have to exist before the rest will land.
        Nothing is written until you have seen the dry run, and any completed
        import can be rolled back.
      </p>

      {(imports ?? []).length === 0 ? (
        <Empty>
          Nothing imported yet.{" "}
          <Link href="/imports/new" className="text-lime-text underline underline-offset-4">
            Start one
          </Link>
          .
        </Empty>
      ) : (
        <Rows>
          {(imports ?? []).map((i) => {
            const r = (i.report ?? {}) as { ok?: number; skip?: number; error?: number };
            return (
              <Link key={i.id} href={`/imports/${i.id}`}
                    className="flex items-center justify-between gap-4 px-3 py-2.5 hover:bg-paper">
                  <div className="min-w-0">
                    <div className="truncate text-[14px] leading-5 text-ink">{i.filename}</div>
                    <div className="text-[12px] leading-4 text-ink-3">
                      {TYPE_LABEL[i.type] ?? i.type} · {i.row_count} row{i.row_count === 1 ? "" : "s"}
                      {i.status === "dry_run_complete" && r.error !== undefined &&
                        ` · ${r.ok ?? 0} ready, ${r.skip ?? 0} skipped, ${r.error ?? 0} with problems`}
                    </div>
                  </div>
                  <StatusPill status={i.status} />
              </Link>
            );
          })}
        </Rows>
      )}
    </AppShell>
  );
}
