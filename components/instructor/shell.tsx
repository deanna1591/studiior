import Link from "next/link";
import TabBar, { type Tab } from "@/components/member/tab-bar";
import { Icon } from "@/components/member/icons";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { InstructorContext } from "@/lib/instructor";

/**
 * The instructor frame — the member app's shell with its own five tabs.
 *
 * Not a stripped-down staff view. An instructor is standing up in a studio
 * between classes, usually in a hurry, on a phone. That is the member app's
 * shape, so this reuses it rather than inventing a third design language: the
 * same tokens, the same tab bar, the same accent handling, the same float and
 * the same blur rule.
 *
 * Branded as the studio, like the member app, and for the same reason: this is
 * Reform Collective's tool, not a tenant of ours wearing our name.
 *
 * FIVE TABS, and the fifth is Home. Availability is monthly, not daily — an
 * instructor sends it once a month and forgets it — so it does not earn a tab
 * and lives under Me. Home leads because the portal should answer "what needs
 * me today" the moment it opens, not present a menu.
 */
const TABS: Tab[] = [
  { href: "/instructor", label: "Home", icon: "home" },
  { href: "/instructor/schedule", label: "My schedule", icon: "calendar" },
  { href: "/instructor/shifts", label: "Claim", icon: "ticket" },
  { href: "/instructor/pay", label: "My pay", icon: "card" },
  { href: "/instructor/me", label: "Me", icon: "user" },
];

export default function InstructorShell({
  ctx, title, children, bare = false, badges = {},
}: {
  ctx: InstructorContext;
  title?: string;
  children: React.ReactNode;
  bare?: boolean;
  badges?: Partial<Record<string, number>>;
}) {
  const preset = (ctx.theme_preset ?? "warm") as PresetKey;
  // Scoped to this subtree, never :root — the staff app shares the stylesheet
  // and keeps Studiior's lime.
  const vars = themeVars(
    preset, ctx.accent_color ?? neutralAccent(preset),
  ) as React.CSSProperties;
  const unread = ctx.unread ?? 0;

  return (
    <div className="m-page" style={vars}>
      {!bare && (
        <header className="mx-auto flex max-w-lg items-center justify-between gap-2 px-4 pb-1 pt-4">
          <div className="min-w-0">
            <p className="m-sub text-ink-3">{ctx.studio_name}</p>
            <p className="truncate text-[15px] font-medium leading-5 text-ink">
              {ctx.display_name}
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {/* The bell — everything the studio sends reaches the instructor by
                email; this is where a deleted email comes back. The count is the
                unread since they last looked. */}
            <Link href="/instructor/notifications" aria-label={
              unread > 0 ? `Notifications, ${unread} unread` : "Notifications"
            } className="relative flex h-9 w-9 items-center justify-center rounded-lg"
                  style={{ background: "var(--accent-chip)" }}>
              <Icon name="bell" size={18} />
              {unread > 0 && (
                <span className="num absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold leading-none"
                      style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}>
                  {unread > 9 ? "9+" : unread}
                </span>
              )}
            </Link>
            {ctx.logo_url && (
              /* A logo goes on a near-white chip, never straight onto the page:
                 most studio logos are a raster with a white background. */
              <span className="flex h-9 w-9 items-center justify-center overflow-hidden rounded-lg bg-white">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={ctx.logo_url} alt="" className="h-full w-full object-contain" />
              </span>
            )}
          </div>
        </header>
      )}
      <main className={`m-scroll mx-auto max-w-lg px-4 pb-24 ${bare ? "pt-4" : "pt-1"}`}>
        {title && <h1 className="m-head mb-5 text-[24px] leading-8 text-ink">{title}</h1>}
        {children}
      </main>
      {!bare && (
        <TabBar
          // Payroll is opt-in (migration 139): a studio that pays in its own
          // books shows no Pay tab at all — absent, not an empty screen.
          tabs={ctx.usesPayroll ? TABS : TABS.filter((t) => t.href !== "/instructor/pay")}
          rootHref="/instructor" badges={badges} />
      )}
    </div>
  );
}
