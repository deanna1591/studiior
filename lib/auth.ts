import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

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
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { kind: "anonymous" };

  const ctx = await getStaffContext();
  if (ctx) return { kind: "staff", ctx };

  const { data: isPlatformAdmin } = await supabase.rpc("is_platform_admin");
  return {
    kind: "no_studio",
    userId: user.id,
    email: user.email ?? "",
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
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase
    .from("studio_staff")
    .select("id, role, studio_id, studios(name, timezone, currency, status)")
    .eq("user_id", user.id)
    .eq("status", "active")
    .maybeSingle();

  if (!data || !data.studios) return null;

  // studio_settings is keyed by studio_id and has no foreign key from
  // studio_staff, so it cannot be embedded in the query above. The primary
  // location comes along for the ride: the rail names the place people are
  // standing in, and a timezone is not that.
  const [{ data: settings }, { data: loc }] = await Promise.all([
    supabase
      .from("studio_settings")
      .select("onboarding_completed_at")
      .eq("studio_id", data.studio_id)
      .maybeSingle(),
    supabase
      .from("locations")
      .select("name")
      .eq("studio_id", data.studio_id)
      .eq("is_primary", true)
      .maybeSingle(),
  ]);

  return {
    userId: user.id,
    email: user.email ?? "",
    staffId: data.id,
    role: data.role as StaffRole,
    studioId: data.studio_id,
    studioName: data.studios.name,
    locationName: loc?.name ?? null,
    timeZone: data.studios.timezone,
    currency: data.studios.currency,
    studioStatus: data.studios.status,
    onboardingComplete: settings?.onboarding_completed_at != null,
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
  studioId: string;
  studioName: string;
  timeZone: string;
};

/** Who is making this request, on the member PWA. */
export async function getMemberContext(): Promise<MemberContext | null> {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase
    .from("members")
    .select("id, first_name, last_name, studio_id, studios(name, timezone)")
    .eq("user_id", user.id)
    .maybeSingle();

  if (!data || !data.studios) return null;

  return {
    userId: user.id,
    memberId: data.id,
    name: `${data.first_name} ${data.last_name}`,
    studioId: data.studio_id,
    studioName: data.studios.name,
    timeZone: data.studios.timezone,
  };
}

export const isManagerUp = (r: StaffRole) => r === "owner" || r === "manager";
export const isDeskUp = (r: StaffRole) =>
  r === "owner" || r === "manager" || r === "front_desk";
