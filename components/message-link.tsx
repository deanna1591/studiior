import Link from "next/link";

/**
 * The message action, everywhere it appears.
 *
 * A text button, never a filled one. The chip is the coloured thing on these
 * screens and a solid button next to it would compete with the only element
 * that is meant to be loud — and on a list of a dozen flagged members, twelve
 * filled buttons is a toolbar, not a list.
 */
export function MessageLink({
  href, className = "", label = "Message",
}: {
  href: string; className?: string; label?: string;
}) {
  return (
    <Link
      href={href}
      className={`inline-flex shrink-0 items-center gap-1.5 rounded text-[12px] leading-4 text-ink-2 underline decoration-line-2 underline-offset-4 hover:text-ink hover:decoration-ink-3 ${className}`}
    >
      <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden className="shrink-0">
        <rect x="0.75" y="2.25" width="10.5" height="7.5" rx="1.25"
              fill="none" stroke="currentColor" strokeWidth="1.1" />
        <path d="M1.5 3.5 6 6.75 10.5 3.5" fill="none" stroke="currentColor"
              strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      {label}
    </Link>
  );
}
