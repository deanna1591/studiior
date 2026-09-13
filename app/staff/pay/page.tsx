import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, Empty, SectionLabel } from "@/components/ui";

export const dynamic = "force-dynamic";

export default async function Pay() {
  const screen = await staffScreen("/pay");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) return <AppShell {...shell} title="Pay"><Denied what="Payroll" role={ctx.role} /></AppShell>;

  const { data: periods } = await supabase.from("pay_periods")
    .select("id, starts_on, ends_on, status").eq("studio_id", ctx.studioId)
    .order("starts_on", { ascending: false }).limit(24);
  const held = await supabase.rpc("studio_unconfirmed_pay_count", { p_studio_id: ctx.studioId });
  const d = (iso: string) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(`${iso}T00:00:00Z`));

  return (
    <AppShell {...shell} title="Pay">
      {(held.data ?? 0) > 0 && (
        <p className="mb-4 max-w-2xl border-l-[3px] px-3 py-2.5 text-[13px] text-ink"
           style={{ borderLeftColor: "var(--coral)", background: "var(--coral-tint)" }}>
          <span className="num font-semibold">{held.data}</span> class{(held.data ?? 0) === 1 ? "" : "es"} unconfirmed — an instructor has not checked in. A period cannot close until every held record is confirmed or released.
        </p>
      )}
      <SectionLabel>Pay periods</SectionLabel>
      {(periods ?? []).length === 0 ? (
        <Empty>No pay periods yet. One is created when there is a class to pay for.</Empty>
      ) : (
        <ul className="s-card mt-3 max-w-2xl divide-y divide-line overflow-hidden">
          {(periods ?? []).map((p) => (
            <li key={p.id}>
              <Link href={`/pay/${p.id}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-paper">
                <span className="text-[14px] text-ink">{d(p.starts_on)} – {d(p.ends_on)}</span>
                <span className="s-tag">{p.status}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </AppShell>
  );
}
