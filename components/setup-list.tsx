import Link from "next/link";
import { AppShell, Empty, Rows, SectionLabel } from "@/components/ui";

type ShellProps = React.ComponentProps<typeof AppShell>;

/** The three setup lists differ only in their rows, so the frame is shared. */
export function SetupShell({
  shell, title, blurb, afterBlurb, newHref, newLabel, empty, count, children, archived, tabs,
}: {
  shell: Omit<ShellProps, "title" | "children">;
  title: string;
  blurb?: string;
  /** A link belonging with the blurb rather than with the page title — a
   *  second destination this list leads to, not a second primary action. */
  afterBlurb?: React.ReactNode;
  newHref: string;
  newLabel: string;
  empty: string;
  count: number;
  /** Optional view switcher, sitting beside the primary action. */
  tabs?: React.ReactNode;
  children: React.ReactNode;
  /** Archived rows, kept in their own section below the live ones. Mixed into
      the list they read as broken records rather than retired ones, and the
      whole point of archiving is that the record survives. */
  archived?: React.ReactNode;
}) {
  return (
    <AppShell
      {...shell}
      title={title}
      actions={
        <>
        {tabs}
        <Link
          href={newHref}
          className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2"
        >
          {newLabel}
        </Link>
        </>
      }
    >
      {blurb && (
        <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
          {blurb}
          {afterBlurb && <> {afterBlurb}</>}
        </p>
      )}
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
      {archived}
    </AppShell>
  );
}

export function SetupRow({
  href, name, meta, right, archived, state,
}: {
  href: string; name: string; meta: string; right?: string; archived?: boolean;
  /**
   * ENDED IS NOT ARCHIVED and the row has to say which.
   *
   * An ended series ran its course or was stopped on a date; it stays on the
   * working list because it is part of what the timetable recently was. An
   * archived one was taken off the list deliberately and lives in its own
   * section. Rendering both in grey with the same word would tell a studio that
   * a series it never touched had been archived.
   */
  state?: "ended" | "archived";
}) {
  const mode = state ?? (archived ? "archived" : undefined);
  return (
    <Link href={href} className="flex items-center justify-between gap-4 px-3 py-2.5 hover:bg-paper">
      <div className="min-w-0">
        <div className={`truncate text-[14px] leading-5 ${mode ? "text-ink-3" : "text-ink"}`}>
          <span className={mode === "ended" ? "line-through decoration-ink-3/60" : undefined}>
            {name}
          </span>
          {mode && (
            <span className="ml-2 text-[12px] leading-4 text-ink-3">
              {mode === "ended" ? "Ended" : "Archived"}
            </span>
          )}
        </div>
        <div className="text-[12px] leading-4 text-ink-3">{meta}</div>
      </div>
      {right && <div className="num shrink-0 text-[13px] text-ink-2">{right}</div>}
    </Link>
  );
}

/**
 * The archived half of a setup list.
 *
 * Below the live records and behind its own heading, not greyed out among
 * them: an archived class type is a retired record, and mixed into the list it
 * reads as a broken one. Rendered only when there is something in it, so a
 * studio that has never archived anything never sees the word.
 */
export function ArchivedSection({ noun, children, count }: {
  noun: string; children: React.ReactNode; count: number;
}) {
  if (count === 0) return null;
  return (
    <section className="mt-8">
      <SectionLabel>Archived</SectionLabel>
      <p className="mb-3 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        Hidden from members. {count} {noun}{count === 1 ? "" : "s"} kept because
        past classes still refer to {count === 1 ? "it" : "them"}. Open one to
        restore it.
      </p>
      <Rows>{children}</Rows>
    </section>
  );
}
