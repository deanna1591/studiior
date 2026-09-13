import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";

export const dynamic = "force-dynamic";

/**
 * Settings is a hub — a list that leads to one screen per group, rather than
 * ten stacked panels that had grown into a wall you scrolled past. A hub (not a
 * persistent side-nav) is also what keeps a settings screen to rail + content
 * at iPad width instead of three columns that do not fit.
 */
export default async function Settings() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Settings"><Denied what="Studio settings" role={ctx.role} /></AppShell>;
  }

  const groups: { href: string; label: string; sub: string }[] = [
    { href: "/settings/timetable", label: "Timetable", sub: "How far ahead classes run, and publishing each month" },
    { href: "/settings/guarantees", label: "Guarantees & flex", sub: "When a class runs regardless, and what it owes the instructor" },
    { href: "/settings/fair-use", label: "Peak & fair use", sub: "Peak hours, repeated late cancellations, and places on a plan" },
    { href: "/settings/features", label: "Member features", sub: "Challenges and guest passes" },
    { href: "/settings/instructors", label: "Instructors", sub: "When the month is due, and when to chase confirmations" },
    { href: "/settings/payroll", label: "Payroll", sub: "How often instructors are paid, and when the period closes" },
    { href: "/settings/closures", label: "Closures", sub: "Days you are shut — nothing is generated, and members are told" },
    { href: "/settings/stripe", label: "Card payments", sub: "Take card payments online (optional — a studio can take cash)" },
  ];
  if (ctx.role === "owner") {
    groups.push({ href: "/branding", label: "Member app", sub: "Colours, logo and the photograph members see" });
  }

  return (
    <AppShell {...shell} title="Settings">
      <ul className="s-card max-w-2xl divide-y divide-line overflow-hidden">
        {groups.map((g) => (
          <li key={g.href}>
            <Link href={g.href} className="flex items-center justify-between gap-3 px-4 py-3.5 hover:bg-paper">
              <span className="min-w-0">
                <span className="block text-[14px] font-semibold text-ink">{g.label}</span>
                <span className="block text-[12px] leading-[17px] text-ink-3">{g.sub}</span>
              </span>
              <span className="shrink-0 text-ink-3">→</span>
            </Link>
          </li>
        ))}
      </ul>
    </AppShell>
  );
}
