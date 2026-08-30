import Link from "next/link";
import { Shell, NavLink } from "@/components/ui";

/** The three setup lists differ only in their rows, so the frame is shared. */
export function SetupShell({
  title, subtitle, newHref, newLabel, empty, children, count,
}: {
  title: string; subtitle: string; newHref: string; newLabel: string;
  empty: string; count: number; children: React.ReactNode;
}) {
  return (
    <Shell
      title={title}
      subtitle={subtitle}
      right={<><NavLink href={newHref}>{newLabel}</NavLink><NavLink href="/">Back to week</NavLink></>}
    >
      {count === 0 ? (
        <p className="text-sm text-stone-600">
          {empty}{" "}
          <Link href={newHref} className="underline underline-offset-4">{newLabel}</Link>.
        </p>
      ) : (
        <ul className="divide-y divide-stone-200 rounded border border-stone-200 bg-white">
          {children}
        </ul>
      )}
    </Shell>
  );
}

export function SetupRow({
  href, name, meta, right, archived,
}: {
  href: string; name: string; meta: string; right?: string; archived?: boolean;
}) {
  return (
    <li>
      <Link href={href}
            className={`flex items-center justify-between gap-4 px-3 py-3 hover:bg-stone-50 ${archived ? "opacity-60" : ""}`}>
        <div className="min-w-0">
          <div className="text-sm font-medium">
            {name}{archived && <span className="ml-2 text-xs font-normal text-stone-500">archived</span>}
          </div>
          <div className="text-xs text-stone-500">{meta}</div>
        </div>
        {right && <div className="shrink-0 text-sm text-stone-600">{right}</div>}
      </Link>
    </li>
  );
}
