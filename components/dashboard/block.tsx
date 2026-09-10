import Link from "next/link";

/**
 * The frame every dashboard block sits in, and the three states it can be in.
 *
 * A FAILED QUERY MUST NOT LOOK LIKE AN EMPTY STUDIO. schedule_range() raised
 * on every call in production for a week and was indistinguishable from a
 * studio with nothing on, so the blankness became the bug report while the
 * error sat unread in the response. Every block takes an `error` and renders
 * it, in words, with the database's own message underneath.
 */
export function Block({
  title, hint, right, error, children,
}: {
  title: string;
  hint?: string;
  right?: React.ReactNode;
  error?: string | null;
  children: React.ReactNode;
}) {
  return (
    <section className="panel">
      <div className="panel-head">
        <div className="min-w-0">
          <h2 className="section-label text-ink-2">{title}</h2>
          {hint && <p className="mt-1 text-[11px] leading-4 text-ink-3">{hint}</p>}
        </div>
        {right && <div className="shrink-0">{right}</div>}
      </div>
      <div className="panel-body">
        {error ? <BlockError message={error} what={title.toLowerCase()} /> : children}
      </div>
    </section>
  );
}

export function BlockError({ message, what }: { message: string; what: string }) {
  return (
    <div className="rounded-lg border-l-[3px] border-coral bg-coral-tint px-3 py-2.5">
      <p className="text-[13px] leading-[19px] text-ink">
        This is not empty — the {what} could not be read. Nothing is wrong with
        your studio&rsquo;s data.
      </p>
      <p className="num mt-1.5 break-words text-[11px] leading-4 text-ink-2">{message}</p>
    </div>
  );
}

/**
 * The empty state, which is part of the work rather than polish.
 *
 * Reform Collective on its first day has one member, no bookings and no
 * takings — so every block renders empty, and a dashboard of zeros looks
 * broken. Each of these says what the block WILL show and what produces it.
 * Never a zero, never a spinner, never a blank card.
 */
export function BlockEmpty({ children, cta }: {
  children: React.ReactNode;
  cta?: { href: string; label: string };
}) {
  return (
    <div className="rounded-lg border border-dashed border-line-2 px-4 py-5">
      <p className="max-w-[52ch] text-[13px] leading-[19px] text-ink-2">{children}</p>
      {cta && (
        <Link
          href={cta.href}
          className="mt-2.5 inline-block text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
        >
          {cta.label}
        </Link>
      )}
    </div>
  );
}

/**
 * A written sentence above a block.
 *
 * Deliberately unlabelled. The Bible's fourth principle is that AI should be
 * invisible, and a badge on every second sentence is the opposite of it — nor
 * is one needed for trust, since the model's version and the deterministic one
 * are checked against the same figures and differ only in voice.
 */
export function Narrative({ text }: { text: string | null | undefined }) {
  if (!text) return null;
  return (
    <p className="mb-3 max-w-[68ch] text-[14px] leading-[21px] text-ink">{text}</p>
  );
}
