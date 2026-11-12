import Link from "next/link";

/**
 * Decision 98 — one free class per person. When a member's free first class is
 * re-flagged as a duplicate (a same-person twin has already had one), the comp
 * seat becomes a 24-hour paid-or-lose hold. This is the line the member sees on
 * Home and on the class page, with the checkout button.
 */
export default function DuplicateHold({
  occurrenceId, className, holdTime,
}: {
  occurrenceId: string;
  className: string;
  holdTime: string | null;
}) {
  return (
    <div className="m-card mt-3 p-4">
      <p className="text-[15px] font-medium leading-5 text-ink">
        {className} is no longer free on your account
      </p>
      <p className="m-sub mt-1 text-ink-2">
        It looks like you&rsquo;ve had a free class with us before.
        {holdTime ? ` Pay to keep your spot before ${holdTime}, or it will be released.` : " Pay to keep your spot, or it will be released."}
      </p>
      <Link href={`/checkout/${occurrenceId}`}
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
            className="m-action m-press mt-3 flex w-full items-center justify-center rounded-xl text-[16px] font-semibold">
        Pay to keep my spot
      </Link>
    </div>
  );
}
