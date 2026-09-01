import Link from "next/link";
import Avatar from "./avatar";
import { Icon } from "./icons";

/**
 * The app bar: studio on the left, the member on the right.
 *
 * The chevron beside the studio name is honest about what it does — it opens
 * the studio's own details, not a switcher. One login can hold memberships at
 * two studios (auth_member_studios() returns a set), but a member reaches the
 * second one at its own subdomain, so a picker here would be a control with one
 * item in it for almost everybody.
 *
 * The bell has no unread count of its own because nothing in the app writes
 * one: notifications are email, and inventing a badge for a screen that does
 * not exist is the "insight without a working button" mistake. It goes to the
 * email settings, which is the only thing a member can actually do about
 * notifications today.
 */
export default function MemberHeader({
  studioName, logoUrl, memberName, avatarUrl,
}: {
  studioName: string;
  logoUrl: string | null;
  memberName: string;
  avatarUrl: string | null;
}) {
  return (
    <header className="sticky top-0 z-20 bg-paper/95 px-4 py-3 backdrop-blur-[2px]">
      <div className="mx-auto flex max-w-lg items-center gap-3">
        <Link href="/account" className="flex min-w-0 flex-1 items-center gap-2.5">
          {logoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={logoUrl} alt="" aria-hidden
                 className="h-8 w-8 rounded-xl bg-white object-contain p-0.5" />
          ) : (
            <span style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="flex h-8 w-8 items-center justify-center rounded-xl text-[14px] font-semibold">
              {studioName.slice(0, 1)}
            </span>
          )}
          <span className="truncate text-[15px] font-semibold leading-5 text-ink">{studioName}</span>
          <Icon name="chevron-down" size={16} className="shrink-0 text-ink-3" />
        </Link>

        <Link href="/settings" aria-label="Email settings"
              className="flex h-10 w-10 items-center justify-center rounded-full text-ink-2">
          <Icon name="bell" size={20} />
        </Link>
        <Link href="/account" aria-label="Your account">
          <Avatar name={memberName} url={avatarUrl} size={36} />
        </Link>
      </div>
    </header>
  );
}
