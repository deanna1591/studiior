import Link from "next/link";
import { isDeskUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { fmtDayLabel } from "@/lib/time";
import { AppShell, Denied, Empty, Rows } from "@/components/ui";
import { StateChip } from "@/components/state-chip";

export const dynamic = "force-dynamic";

/**
 * Decision 86 / Decision 30. Where the free-first conversion card lands: the
 * people who took a free first class, each marked converted (they went on to
 * buy) or not. Decision 26's host-guest count is NOT a dashboard card — its
 * number survives here as one line, "n brought by a member", and nothing more.
 * Desk-up.
 */

type Member = {
  member_id: string;
  name: string;
  free_class_date: string | null;
  converted: boolean;
  plan_bought: string | null;
};
type Block = { members: Member[]; brought_by_member: number };

export default async function FreeClassesPage() {
  const screen = await staffScreen("/dashboard/free-classes");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;

  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Free first classes"><Denied what="members" role={ctx.role} /></AppShell>;
  }

  const { data, error } = await supabase.rpc("dashboard_free_first_members", { p_studio_id: ctx.studioId });
  const block = (data ?? { members: [], brought_by_member: 0 }) as Block;
  const converted = block.members.filter((m) => m.converted).length;

  return (
    <AppShell
      {...shell}
      title="Free first classes"
      actions={
        <Link href="/" className="text-[13px] text-ink-3 underline underline-offset-4 hover:text-ink">
          Back to the dashboard
        </Link>
      }
    >
      {error ? (
        <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
          <p className="text-[13px] leading-[19px] text-ink">
            The free-class list could not be read. This is not a studio with none.
          </p>
          <p className="num mt-1.5 text-[11px] leading-4 text-ink-2">{error.message}</p>
        </div>
      ) : block.members.length === 0 ? (
        <Empty>Nobody has taken a free first class yet.</Empty>
      ) : (
        <>
          <div className="panel mb-3 flex flex-col gap-1 p-4">
            <span className="text-[13px] leading-5 text-ink">
              <span className="num font-semibold">{converted}</span> of{" "}
              <span className="num font-semibold">{block.members.length}</span> went on to buy a plan.
            </span>
            {block.brought_by_member > 0 && (
              <span className="text-[12px] leading-4 text-ink-3">
                <span className="num">{block.brought_by_member}</span> brought by a member.
              </span>
            )}
          </div>
          <Rows>
            {block.members.map((m) => (
              <div key={m.member_id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-3 py-2.5">
                <span className="flex min-w-0 flex-col">
                  <Link href={`/members/${m.member_id}`} className="truncate text-[14px] font-medium leading-5 text-ink hover:underline underline-offset-2">
                    {m.name}
                  </Link>
                  {m.free_class_date && (
                    <span className="text-[12px] leading-4 text-ink-3">
                      Free class <span className="num">{fmtDayLabel(m.free_class_date, ctx.timeZone)}</span>
                    </span>
                  )}
                </span>
                {m.converted ? (
                  <span className="text-[12px] leading-4 text-lime-text">Bought {m.plan_bought ?? "a plan"}</span>
                ) : (
                  <StateChip state="free_taken" />
                )}
              </div>
            ))}
          </Rows>
        </>
      )}
    </AppShell>
  );
}
