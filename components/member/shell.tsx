import TabBar from "./tab-bar";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";

/**
 * The member frame. Branded as the studio: its name and, when it has one, its
 * logo. The word "Studiior" does not appear anywhere a member can see it —
 * this is Reform Collective's app, not a tenant of ours wearing our name.
 *
 * brand_color is deliberately not used. It is an arbitrary hex with unverified
 * contrast, and letting it drive text or fills would silently break every
 * ratio this palette was measured for. Identity is carried by the logo and the
 * name.
 */
export default function MemberShell({
  studioName, logoUrl, title, children, bare = false,
  preset = "warm", accent, openOffers = 0,
}: {
  studioName: string;
  logoUrl: string | null;
  title?: string;
  children: React.ReactNode;
  bare?: boolean;
  preset?: PresetKey;
  accent?: string | null;
  /** Live waitlist offers awaiting an answer — the Home tab's badge. */
  openOffers?: number;
}) {
  // Scoped to this subtree, not :root — the staff app shares the same stylesheet
  // and must keep Studiior's lime. A studio brands what its members see.
  const vars = themeVars(preset, accent ?? neutralAccent(preset)) as React.CSSProperties;
  return (
    <div className="min-h-dvh bg-paper" style={vars}>
      {!bare && (
        <header className="sticky top-0 z-20 border-b border-line bg-surface px-4 py-3">
          <div className="mx-auto flex max-w-lg items-center gap-2.5">
            {logoUrl ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={logoUrl} alt={studioName} className="h-7 w-7 rounded object-cover" />
            ) : (
              <span
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                className="flex h-7 w-7 items-center justify-center rounded text-[13px] font-semibold"
              >
                {studioName.slice(0, 1)}
              </span>
            )}
            <span className="truncate text-[15px] font-medium leading-5 text-ink">{studioName}</span>
          </div>
        </header>
      )}
      <main className={`m-scroll mx-auto max-w-lg px-4 ${bare ? "pt-4" : "pt-4"}`}>
        {title && <h1 className="m-display mb-4 text-ink">{title}</h1>}
        {children}
      </main>
      <TabBar badges={{ "/": openOffers }} />
    </div>
  );
}
