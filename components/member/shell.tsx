import TabBar from "./tab-bar";
import MemberHeader from "./header";
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
  memberName = "", avatarUrl = null,
}: {
  studioName: string;
  logoUrl: string | null;
  memberName?: string;
  avatarUrl?: string | null;
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
        <MemberHeader
          studioName={studioName}
          logoUrl={logoUrl}
          memberName={memberName}
          avatarUrl={avatarUrl}
        />
      )}
      <main className={`m-scroll mx-auto max-w-lg px-4 ${bare ? "pt-4" : "pt-2"}`}>
        {title && <h1 className="m-display mb-5 text-ink">{title}</h1>}
        {children}
      </main>
      <TabBar badges={{ "/": openOffers }} />
    </div>
  );
}
