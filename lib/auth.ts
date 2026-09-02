import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { currentSlug } from "@/lib/tenant";

export type StaffRole = "owner" | "manager" | "instructor" | "front_desk";

export type StaffContext = {
  userId: string;
  email: string;
  staffId: string;
  role: StaffRole;
  studioId: string;
  studioName: string;
  locationName: string | null;
  timeZone: string;
  currency: string;
  onboardingComplete: boolean;
  studioStatus: string;
  /** Both arrive with the context now rather than as their own requests. */
  isPlatformAdmin: boolean;
  billing: { status: string | null; locked: boolean; daysLeft: number };
};

/**
 * Who is making this request, on the staff app.
 *
 * The role is read from studio_staff, not from anything the client sent. It
 * decides what the UI offers; RLS decides what the database actually allows,
 * and those are not the same thing. A front desk user can reach the create-class
 * form by typing the URL — the insert is refused by occ_manager_write, and that
 * refusal is the real permission.
 */
/**
 * The three ways a request can arrive at a staff screen.
 *
 * Collapsing the last two into `null` is what caused the sign-in loop: a
 * platform admin has no studio_staff row anywhere — by design, they operate the
 * platform rather than a studio — so "not staff of any studio" was read as "not
 * signed in", bounced to /login, signed in again, and round it went. They are
 * different states and they need different answers.
 */
export type StaffAccess =
  | { kind: "anonymous" }
  | { kind: "no_studio"; userId: string; email: string; isPlatformAdmin: boolean }
  | { kind: "staff"; ctx: StaffContext };

export async function getStaffAccess(): Promise<StaffAccess> {
  const supabase = createClient();
  // getClaims(), verified locally — see currentUserId() below. This used to be
  // getUser(), and then getStaffContext() called getUser() again a line later:
  // two network round trips to GoTrue to establish one identity.
  const userId = await currentUserId();
  if (!userId) return { kind: "anonymous" };

  const ctx = await getStaffContext();
  if (ctx) return { kind: "staff", ctx };

  // Only for the caller who is staff of nowhere — a platform admin, which is
  // the rare path. The common one has already answered this inside the
  // bootstrap.
  const { data: isPlatformAdmin } = await supabase.rpc("is_platform_admin");
  const { data: claims } = await supabase.auth.getClaims();
  return {
    kind: "no_studio",
    userId,
    email: (claims?.claims?.email as string | undefined) ?? "",
    isPlatformAdmin: isPlatformAdmin === true,
  };
}

/**
 * Staff context for one studio, or null when the caller is not active staff of
 * any studio — which includes both "signed out" and "signed in, but a platform
 * admin". Pages must use getStaffAccess() to tell those apart; this stays for
 * server actions, where "not staff of a studio" is the precondition that
 * matters and both cases are equally a refusal.
 */
export async function getStaffContext(): Promise<StaffContext | null> {
  const supabase = createClient();

  // One request. It used to be getUser(), then the staff row, then
  // studio_settings and locations in parallel — and the last two could not
  // start until the staff row named the studio.
  const { data } = await supabase.rpc("staff_bootstrap");
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return null;

  return {
    userId: row.user_id,
    email: row.email ?? "",
    staffId: row.staff_id,
    role: row.role as StaffRole,
    studioId: row.studio_id,
    studioName: row.studio_name,
    locationName: row.location_name ?? null,
    timeZone: row.studio_timezone,
    currency: row.studio_currency,
    studioStatus: row.studio_status,
    onboardingComplete: row.onboarding_complete === true,
    isPlatformAdmin: row.is_platform_admin === true,
    billing: {
      status: row.billing_status,
      locked: row.billing_locked === true,
      daysLeft: row.billing_days_left ?? 0,
    },
  };
}

/**
 * The wizard gate, for a caller already known to be staff.
 *
 * Deliberately takes a context rather than fetching one, so it cannot repeat
 * the mistake above: deciding what to do about a non-staff caller is the
 * page's job, through getStaffAccess() and <StaffAccessGate>.
 */
export function requireOnboarded(ctx: StaffContext): StaffContext {
  if (!ctx.onboardingComplete) redirect("/welcome");
  return ctx;
}

export type MemberContext = {
  userId: string;
  memberId: string;
  name: string;
  firstName: string;
  studioId: string;
  studioName: string;
  timeZone: string;
  status: string;
  /** Caches on members, recomputed on check-in and nightly (Business Rules §8). */
  streak: number;
  lifetimeVisits: number;
  /**
   * Everything member_bootstrap() returned, carried so memberScreen() does not
   * have to ask again. This is the whole point of the one-trip bootstrap: the
   * studio, its settings and its billing state arrive with the member.
   */
  bootstrap?: MemberBootstrap;
};

export type MemberBootstrap = {
  member_id: string; studio_id: string;
  first_name: string; last_name: string; preferred_name: string | null;
  avatar_path: string | null;
  studio_name: string; studio_timezone: string;
  logo_url: string | null; theme_preset: string | null; accent_color: string | null;
  checkin_opens_minutes_before: number; checkin_closes_minutes_after: number;
  cancellation_cutoff_minutes: number; booking_cutoff_minutes: number;
  waitlist_enabled: boolean;
  billing_locked: boolean;
  open_offers: number;
};

/** Who is making this request, on the member PWA. */
/**
 * Who is making this request, on the member PWA, and at WHICH studio.
 *
 * The studio comes from the subdomain, and it has to: one login can hold
 * memberships at several studios, because auth.users has a global unique index
 * on email — one address is one account, project-wide, whatever Permissions
 * line 267 used to say. This previously selected on user_id alone with
 * .maybeSingle(), so the moment somebody joined a second studio PostgREST
 * errored on the two rows, this returned null, and the member app told them
 * they had no studio access. Scoping by studio fixes it properly; taking the
 * first row would have hidden it and shown people the wrong studio's data.
 */
/**
 * Who is signed in, without a round trip.
 *
 * getClaims() verifies the JWT signature LOCALLY, with WebCrypto against a
 * cached JWKS — it is not getSession(), which reads the cookie and checks
 * nothing. Both this project's local stack and its hosted one sign ES256.
 *
 * It falls back to a network getUser() for symmetric HS256 keys, silently, so
 * assertAsymmetricSigning() below exists to make that visible rather than to
 * let it quietly cost what it used to.
 *
 * Even if this were wrong, no data would follow from it: PostgREST verifies the
 * signature on every request (a forged one is 401 PGRST301, an expired one the
 * same), and every policy keys on auth.uid() from that verified claim rather
 * than on anything read here.
 */
async function currentUserId(): Promise<string | null> {
  void assertAsymmetricSigning();
  const supabase = createClient();
  const { data } = await supabase.auth.getClaims();
  return data?.claims?.sub ?? null;
}

export async function getMemberContext(): Promise<MemberContext | null> {
  const supabase = createClient();
  const userId = await currentUserId();
  if (!userId) return null;

  const slug = currentSlug();
  if (!slug) return null;

  // One request for the member, their studio, its settings, its billing state
  // and any live offer. This used to be the member lookup followed by four more
  // that could not start until it returned.
  const { data } = await supabase.rpc("member_bootstrap", { p_slug: slug });
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return null;

  return {
    userId,
    memberId: row.member_id,
    name: `${row.first_name} ${row.last_name}`,
    firstName: row.first_name,
    status: row.status,
    streak: row.current_streak ?? 0,
    lifetimeVisits: row.lifetime_visits ?? 0,
    studioId: row.studio_id,
    studioName: row.studio_name,
    timeZone: row.studio_timezone,
    bootstrap: row,
  };
}

export const isManagerUp = (r: StaffRole) => r === "owner" || r === "manager";
export const isDeskUp = (r: StaffRole) =>
  r === "owner" || r === "manager" || r === "front_desk";

/**
 * Fail loudly if this project stops signing asymmetrically.
 *
 * getClaims() verifies the JWT locally against a cached JWKS for ES256 and
 * RS256, and silently falls back to a network getUser() for symmetric HS256.
 * Silently is the problem: the app would still be correct, still pass every
 * test, and quietly cost a round trip per request again — which is precisely
 * the local-versus-hosted trap that migrations 006, 011 and 033 were each
 * written to undo.
 *
 * Checked once per process against the project's public JWKS, and only warned
 * about: refusing to boot over a performance regression would be worse than
 * the regression.
 */
let signingChecked = false;
export async function assertAsymmetricSigning() {
  if (signingChecked) return;
  signingChecked = true;
  try {
    const url = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/.well-known/jwks.json`;
    const jwks = await fetch(url, { cache: "force-cache" }).then((r) => r.json());
    const keys: { alg?: string; kty?: string }[] = jwks?.keys ?? [];
    const asymmetric = keys.some((k) => k.kty === "EC" || k.kty === "RSA");
    if (!asymmetric) {
      console.warn(
        "[auth] This project is not signing asymmetrically, so getClaims() is " +
        "falling back to a network call to GoTrue on every request. The member " +
        "app will be roughly one round trip slower per navigation. Switch the " +
        "project to asymmetric JWT signing keys to get it back.",
      );
    }
  } catch {
    // A JWKS fetch that fails tells us nothing worth crashing over.
  }
}
