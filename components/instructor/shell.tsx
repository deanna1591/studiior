import TabBar, { type Tab } from "@/components/member/tab-bar";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";
import type { InstructorContext } from "@/lib/instructor";

/**
 * The instructor frame — the member app's shell with five different tabs.
 *
 * Not a stripped-down staff view. An instructor is standing up in a studio
 * between classes, usually in a hurry, on a phone. That is the member app's
 * shape, so this reuses it rather than inventing a third design language: the
 * same tokens, the same tab bar, the same accent handling, the same float and
 * the same blur rule.
 *
 * Branded as the studio, like the member app, and for the same reason: this is
 * Reform Collective's tool, not a tenant of ours wearing our name.
 */
const TABS: Tab[] = [
  // My week first. It is the thing they open — everything else is something
  // they go looking for.
  { href: "/instructor", label: "My week", icon: "calendar" },
  { href: "/instructor/shifts", label: "Shifts", icon: "home" },
  { href: "/instructor/availability", label: "When I'm free", icon: "clock" },
  { href: "/instructor/pay", label: "Pay", icon: "qr" },
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

  return (
    <div className="m-page" style={vars}>
      {!bare && (
        <header className="mx-auto flex max-w-lg items-center justify-between px-4 pb-1 pt-4">
          <div className="min-w-0">
            <p className="m-sub text-ink-3">{ctx.studio_name}</p>
            <p className="truncate text-[15px] font-medium leading-5 text-ink">
              {ctx.display_name}
            </p>
          </div>
          {ctx.logo_url && (
            /* A logo goes on a near-white chip, never straight onto the page:
               most studio logos are a raster with a white background. */
            <span className="ml-3 flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-white">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={ctx.logo_url} alt="" className="h-full w-full object-contain" />
            </span>
          )}
        </header>
      )}
      <main className={`m-scroll mx-auto max-w-lg px-4 pb-24 ${bare ? "pt-4" : "pt-1"}`}>
        {title && <h1 className="m-head mb-5 text-[24px] leading-8 text-ink">{title}</h1>}
        {children}
      </main>
      {!bare && <TabBar tabs={TABS} rootHref="/instructor" badges={badges} />}
    </div>
  );
}
