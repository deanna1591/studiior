import Link from "next/link";
import { AppShell, Empty, Rows } from "@/components/ui";

type ShellProps = React.ComponentProps<typeof AppShell>;

/** The three setup lists differ only in their rows, so the frame is shared. */
export function SetupShell({
  shell, title, blurb, newHref, newLabel, empty, count, children,
}: {
  shell: Omit<ShellProps, "title" | "children">;
  title: string;
  blurb?: string;
  newHref: string;
  newLabel: string;
  empty: string;
  count: number;
  children: React.ReactNode;
}) {
  return (
    <AppShell
      {...shell}
      title={title}
      actions={
        <Link
          href={newHref}
          className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2"
        >
          {newLabel}
        </Link>
      }
    >
      {blurb && <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">{blurb}</p>}
      {count === 0 ? (
        <Empty>
          {empty}{" "}
          <Link href={newHref} className="text-lime-text underline underline-offset-4">
            {newLabel.toLowerCase()}
          </Link>
          .
        </Empty>
      ) : (
        <Rows>{children}</Rows>
      )}
    </AppShell>
  );
}

export function SetupRow({
  href, name, meta, right, archived,
}: {
  href: string; name: string; meta: string; right?: string; archived?: boolean;
}) {
  return (
    <Link href={href} className="flex items-center justify-between gap-4 px-3 py-2.5 hover:bg-paper">
      <div className="min-w-0">
        <div className={`truncate text-[14px] leading-5 ${archived ? "text-ink-3" : "text-ink"}`}>
          {name}
          {archived && (
            <span className="ml-2 text-[12px] leading-4 text-ink-3">Archived</span>
          )}
        </div>
        <div className="text-[12px] leading-4 text-ink-3">{meta}</div>
      </div>
      {right && <div className="num shrink-0 text-[13px] text-ink-2">{right}</div>}
    </Link>
  );
}
