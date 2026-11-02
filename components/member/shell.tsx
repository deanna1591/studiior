import TabBar from "./tab-bar";
import MemberHeader from "./header";
import { getMemberContext } from "@/lib/auth";
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
export default async function MemberShell({
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
  // Decision 89 (a): the header's message icon. Read from the cached bootstrap
  // the page already fetched (getMemberContext is React-cache()'d), so this adds
  // no wave. Skipped entirely for a bare frame (signed-out /buy, /checkin).
  const mctx = bare ? null : await getMemberContext();
  return (
    <div className="m-page" style={vars}>
      {!bare && (
        <MemberHeader
          studioName={studioName}
          logoUrl={logoUrl}
          memberName={memberName}
          avatarUrl={avatarUrl}
          messagesEnabled={mctx?.bootstrap?.messages_enabled ?? false}
          hasUnreadMessage={mctx?.bootstrap?.has_unread_studio_message ?? false}
        />
      )}
      <main className={`m-scroll mx-auto max-w-lg px-4 pb-24 ${bare ? "pt-4" : "pt-1"}`}>
        {title && <h1 className="m-head text-[24px] leading-8 mb-5 text-ink">{title}</h1>}
        {children}
      </main>
      <TabBar badges={{ "/": openOffers }} />
    </div>
  );
}
