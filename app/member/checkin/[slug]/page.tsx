import Link from "next/link";
import { getMemberContext } from "@/lib/auth";
import { memberScreen } from "@/lib/member";
import { anonStudio } from "@/lib/anon-studio";
import MemberShell from "@/components/member/shell";
import SelfCheckIn from "@/components/member/self-check-in";
import { fmtTime } from "@/lib/time";
import { checkinNotice } from "@/lib/checkin-notice";
import { themeVars, neutralAccent, type PresetKey } from "@/lib/theme";

export const dynamic = "force-dynamic";

type Occ = {
  id: string; name: string; starts_at: string; ends_at: string | null;
  locations: { latitude: number | null; longitude: number | null; self_checkin_requires_location: boolean } | null;
};
type Booking = { id: string; occurrence_id: string; class_occurrences: Occ | null };

/**
 * Decision 35 §3 — the printed studio QR opens here. Signed-out → login with
 * ?next back here (Decision 41). Signed-in → the slug must be THIS studio's
 * (the host names the studio, the slug is the check-in token); then the
 * member's open booking(s) run the SAME self_check_in the Home card does — no
 * new writer. A location with no coordinates that requires one → "at the desk".
 */
export default async function Checkin({ params }: { params: { slug: string } }) {
  const next = `/checkin/${params.slug}`;
  const ctx = await getMemberContext();

  // Signed out — a themed frame (NOT MemberShell), mirroring /buy.
  if (!ctx) {
    const studio = await anonStudio();
    const preset = (studio?.theme_preset ?? "warm") as PresetKey;
    const accent = studio?.accent_color ?? neutralAccent(preset);
    const vars = themeVars(preset, accent) as React.CSSProperties;
    return (
      <div className="m-page min-h-screen" style={vars}>
        <main className="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center px-5 text-center">
          {studio?.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={studio.logo_url} alt="" className="mb-5 h-16 w-16 rounded-2xl object-contain" />
          ) : null}
          {studio?.name && <p className="m-head text-[22px] leading-7 text-ink">{studio.name}</p>}
          <p className="m-body mt-2 text-ink-2">Sign in to check in to your class.</p>
          <div className="mt-6 w-full max-w-xs space-y-3">
            <Link href={`/login?next=${encodeURIComponent(next)}`}
                  style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
                  className="m-action m-press flex w-full items-center justify-center rounded-xl text-[16px] font-semibold">
              Sign in
            </Link>
            <Link href={`/signup?next=${encodeURIComponent(next)}`}
                  className="m-action m-press flex w-full items-center justify-center rounded-xl border border-line-2 bg-surface text-[16px] font-semibold text-ink">
              Create an account
            </Link>
          </div>
        </main>
      </div>
    );
  }

  // Signed in.
  const { supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl, settings } =
    await memberScreen();

  const Frame = ({ children }: { children: React.ReactNode }) => (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <h1 className="m-title mb-4 text-ink">Check in</h1>
      {children}
    </MemberShell>
  );
  const card = (body: React.ReactNode) => <Frame><div className="m-card p-5 text-center">{body}</div></Frame>;

  // The slug must belong to THIS studio (the host). An authed reader resolves
  // it to a studio id — no anon surface touched.
  const { data: slugStudio } = await supabase.rpc("checkin_slug_studio", { p_slug: params.slug });
  if (!slugStudio) return card(<p className="m-body text-ink">This check-in code isn&rsquo;t valid.</p>);
  if (slugStudio !== ctx.studioId) {
    return card(<p className="m-body text-ink">This code belongs to a different studio.</p>);
  }

  // Waiver at the door (Decision 34/35). The member-callable current_waiver
  // gives require_waiver, whether a version exists, and whether THIS member has
  // signed it; "blocked" is require_waiver AND a version AND not signed, which
  // mirrors the service-only member_waiver_current. The self_check_in PT422
  // stays the backstop for a stale page.
  const { data: cw } = await supabase.rpc("current_waiver", { p_studio_id: ctx.studioId });
  const w = cw as { exists?: boolean; require_waiver?: boolean; signed?: boolean } | null;
  const waiverBlocked = !!(w?.require_waiver && w.exists && !w.signed);

  // The member's own live bookings at this studio, with the occurrence + its
  // location, so the window and the geofence availability are computed here —
  // the same shape as the Home card.
  const { data } = await supabase.from("bookings")
    .select("id, occurrence_id, class_occurrences(id, name, starts_at, ends_at, locations(latitude, longitude, self_checkin_requires_location))")
    .eq("member_id", ctx.memberId).in("status", ["booked", "attended"]);

  const now = Date.now();
  const opensBefore = settings.checkinOpensBefore;
  const closesAfter = settings.checkinClosesAfter;
  const fmt = (ms: number) => fmtTime(new Date(ms).toISOString(), ctx.timeZone, ctx.timeFormat);
  const dayKey = (d: Date) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: ctx.timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  const todayKey = dayKey(new Date(now));

  const bookings = ((data ?? []) as unknown as Booking[])
    .filter((b) => b.class_occurrences)
    .sort((a, b) =>
      new Date(a.class_occurrences!.starts_at).getTime() - new Date(b.class_occurrences!.starts_at).getTime());

  const startMs = (b: Booking) => new Date(b.class_occurrences!.starts_at).getTime();
  const closeMs = (b: Booking) =>
    new Date(b.class_occurrences!.ends_at ?? b.class_occurrences!.starts_at).getTime() + closesAfter * 60e3;
  const windowOpen = (o: Occ) => {
    const opens = new Date(o.starts_at).getTime() - opensBefore * 60e3;
    const closes = new Date(o.ends_at ?? o.starts_at).getTime() + closesAfter * 60e3;
    return now >= opens && now <= closes;
  };
  const available = (o: Occ) => {
    const loc = o.locations;
    if (!loc) return false;
    return loc.self_checkin_requires_location === false || (loc.latitude != null && loc.longitude != null);
  };

  const open = bookings.filter((b) => windowOpen(b.class_occurrences!));

  // Decision 35 amendment: the waiver notice card, above the check-in button.
  const waiverCard = (
    <div className="m-card mb-3 p-4 text-left"
         style={{ borderLeft: "3px solid var(--coral)", background: "var(--coral-tint)" }}>
      <p className="m-body text-ink">Please sign the waiver first before checking in.</p>
      <Link href={`/waiver?next=${encodeURIComponent(next)}`}
            className="m-press mt-2 inline-block rounded-lg px-3 py-1.5 text-[13px] font-semibold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        Sign the waiver
      </Link>
    </div>
  );

  // No open window — say WHY rather than a bare "no class". Pick today's most
  // relevant booking: the next one whose window is still ahead, else the last
  // one whose window has closed; the pure helper chooses the sentence.
  if (open.length === 0) {
    const todays = bookings.filter((b) => dayKey(new Date(b.class_occurrences!.starts_at)) === todayKey);
    const laterToday = todays.filter((b) => now < startMs(b) - opensBefore * 60e3)[0];
    const closedToday = [...todays].reverse().find((b) => now > closeMs(b));
    const rel = laterToday ?? closedToday ?? null;
    const o = rel?.class_occurrences ?? null;
    const notice = checkinNotice({
      booking: o ? { name: o.name, startsAt: new Date(o.starts_at).getTime(), endsAt: o.ends_at ? new Date(o.ends_at).getTime() : null } : null,
      now, opensBefore, closesAfter, waiverOk: true, fmt,
    });
    const nextUp = bookings.find((b) => startMs(b) > now);
    return card(
      <>
        <p className="m-body text-ink">{notice.text}</p>
        {notice.kind === "none" && nextUp && (
          <p className="m-sub mt-1 text-ink-2">
            Your next class is {new Intl.DateTimeFormat("en-GB", { weekday: "long", timeZone: ctx.timeZone }).format(new Date(nextUp.class_occurrences!.starts_at))}{" "}
            at <span className="num">{fmtTime(nextUp.class_occurrences!.starts_at, ctx.timeZone, ctx.timeFormat)}</span>.
          </p>
        )}
      </>,
    );
  }

  // A location that requires coordinates but has none → the door QR can't place
  // anyone; the instructor checks them in (Decision 35 §7, absence not a switch).
  const noGeofence = open.every((b) => !available(b.class_occurrences!));
  if (noGeofence) {
    return card(<p className="m-body text-ink">Check in with your instructor.</p>);
  }

  return (
    <Frame>
      {waiverBlocked && waiverCard}
      <p className="m-sub mb-3 text-ink-2">
        {open.length === 1 ? "You're booked into this class." : "Pick the class you're here for."}
      </p>
      <ul className="space-y-3">
        {open.map((b) => {
          const o = b.class_occurrences!;
          return (
            <li key={b.id} className="m-card flex items-center justify-between gap-3 p-4">
              <span className="min-w-0">
                <span className="block truncate text-[16px] font-semibold text-ink">{o.name}</span>
                <span className="m-sub block text-ink-2">
                  <span className="num">{fmtTime(o.starts_at, ctx.timeZone, ctx.timeFormat)}</span>
                </span>
              </span>
              {available(o)
                ? <SelfCheckIn bookingId={b.id} blocked={waiverBlocked} />
                : <span className="m-sub shrink-0 text-ink-3">With your instructor</span>}
            </li>
          );
        })}
      </ul>
    </Frame>
  );
}
