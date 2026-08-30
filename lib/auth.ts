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
    .select("id, role, studio_id, studios(name, timezone, currency)")
    .eq("user_id", user.id)
    .eq("status", "active")
    .maybeSingle();

  if (!data || !data.studios) return null;

  return {
    userId: user.id,
    email: user.email ?? "",
    staffId: data.id,
    role: data.role as StaffRole,
    studioId: data.studio_id,
    studioName: data.studios.name,
    timeZone: data.studios.timezone,
    currency: data.studios.currency,
  };
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
