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
  // studio_staff, so it cannot be embedded in the query above.
  const { data: settings } = await supabase
    .from("studio_settings")
    .select("onboarding_completed_at")
    .eq("studio_id", data.studio_id)
    .maybeSingle();

  return {
    userId: user.id,
    email: user.email ?? "",
    staffId: data.id,
    role: data.role as StaffRole,
    studioId: data.studio_id,
    studioName: data.studios.name,
    timeZone: data.studios.timezone,
    currency: data.studios.currency,
    studioStatus: data.studios.status,
    onboardingComplete: settings?.onboarding_completed_at != null,
  };
}

/**
 * Staff context for a screen that the setup wizard should block.
 *
 * The wizard is linear and must finish before the rest of the app is usable,
 * so every screen behind it funnels through here rather than each remembering
 * to check. Returns null only when signed out; otherwise it either returns a
 * context or redirects.
 */
export async function requireOnboardedStaff(): Promise<StaffContext> {
  const ctx = await getStaffContext();
  if (!ctx) redirect("/login");
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
