"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getStaffContext } from "@/lib/auth";
import { FIELDS, toCents, type PlanType } from "@/lib/plans";
import type { Database } from "@/lib/database.types";

/** The generated row type, minus the tenant key the action supplies itself. */
type PlanFields = Omit<Database["public"]["Tables"]["membership_plans"]["Insert"], "studio_id">;

export type PlanFormState = { error: string } | null;

/**
 * Build the row from the form, dropping everything the plan type does not use.
 *
 * The form hides those fields; this is what makes them actually absent. A
 * client can post whatever it likes, so billing_interval on a class pack is
 * discarded here rather than trusted because the UI would not have offered it.
 */
type ReadResult =
  | { ok: false; error: string }
  | { ok: true; row: PlanFields };

function readForm(fd: FormData, currency: string): ReadResult {
  const type = String(fd.get("type") ?? "") as PlanType;
  const f = FIELDS[type];
  if (!f) return { ok: false, error: "Pick a plan type." };

  const name = String(fd.get("name") ?? "").trim();
  if (!name) return { ok: false, error: "A plan needs a name." };

  const price = toCents(String(fd.get("price") ?? ""));
  if (price === null) return { ok: false, error: "Price must be an amount like 2800 or 2800.00." };

  const signup = toCents(String(fd.get("signup_fee") ?? "0")) ?? 0;

  const num = (key: string): number | null => {
    const raw = String(fd.get(key) ?? "").trim();
    if (raw === "") return null;
    const n = Number(raw);
    return Number.isFinite(n) && n >= 0 ? Math.floor(n) : null;
  };

  const classTypeIds = fd.getAll("class_type_ids").map(String).filter(Boolean);

  return {
    ok: true,
    row: {
      name,
      description: String(fd.get("description") ?? "").trim() || null,
      type,
      price_cents: price,
      currency,
      visibility: String(fd.get("visibility") ?? "public"),
      status: String(fd.get("status") ?? "active"),
      signup_fee_cents: signup,

      billing_interval: f.billing
        ? (String(fd.get("billing_interval") ?? "month") as "week" | "month" | "quarter" | "year")
        : null,
      billing_interval_count: f.billing ? (num("billing_interval_count") ?? 1) : 1,

      credits: f.credits ? num("credits") : null,
      credits_per_period: f.creditsPerPeriod ? num("credits_per_period") : null,
      validity_days: f.validity ? num("validity_days") : null,

      commitment_months: f.commitment ? (num("commitment_months") ?? 0) : 0,
      cancellation_notice_days: f.commitment ? (num("cancellation_notice_days") ?? 0) : 0,
      freeze_allowed: f.freeze ? fd.get("freeze_allowed") === "on" : false,
      max_freeze_days: f.freeze ? num("max_freeze_days") : null,

      booking_window_days: num("booking_window_days"),
      max_bookings_per_day: num("max_bookings_per_day"),

      // {class_type_ids: []} is "covers everything" to book_class(), so an
      // empty selection stores an empty object rather than an empty array.
      restrictions: classTypeIds.length > 0 ? { class_type_ids: classTypeIds } : {},

      // No Stripe wiring in this step.
      stripe_product_id: null,
      stripe_price_id: null,
    },
  };
}

export async function createPlan(_prev: PlanFormState, fd: FormData): Promise<PlanFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const parsed = readForm(fd, ctx.currency);
  if (!parsed.ok) return { error: parsed.error };

  const supabase = createClient();
  // No role check here. plans_manager_write decides; front desk and instructors
  // are refused by the policy, which is the permission that actually exists.
  const { data, error } = await supabase
    .from("membership_plans")
    .insert({ ...parsed.row, studio_id: ctx.studioId })
    .select("id")
    .single();

  if (error) {
    return /row-level security/i.test(error.message) || error.code === "42501"
      ? { error: "Your role cannot create plans. Owners and managers only." }
      : { error: error.message };
  }

  revalidatePath("/plans");
  redirect(`/plans/${data.id}?saved=1`);
}

export async function updatePlan(_prev: PlanFormState, fd: FormData): Promise<PlanFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const id = String(fd.get("id") ?? "");
  const parsed = readForm(fd, ctx.currency);
  if (!parsed.ok) return { error: parsed.error };

  const supabase = createClient();
  const { data, error } = await supabase
    .from("membership_plans")
    .update(parsed.row)
    .eq("id", id)
    .select("id");

  if (error) return { error: error.message };

  // RLS blocks an UPDATE by making the row invisible, not by raising. Without
  // this check a refused edit returns no error and zero rows, and the screen
  // would cheerfully report "saved" having changed nothing.
  if (!data || data.length === 0) {
    return { error: "Your role cannot edit plans. Owners and managers only." };
  }

  revalidatePath("/plans");
  revalidatePath(`/plans/${id}`);
  redirect(`/plans/${id}?saved=1`);
}

export async function setPlanStatus(_prev: PlanFormState, fd: FormData): Promise<PlanFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const id = String(fd.get("id") ?? "");
  const status = String(fd.get("status") ?? "");
  if (status !== "active" && status !== "archived") return { error: "Unknown status." };

  const supabase = createClient();
  const { data, error } = await supabase
    .from("membership_plans")
    .update({ status })
    .eq("id", id)
    .select("id");

  if (error) return { error: error.message };
  if (!data || data.length === 0) {
    return { error: "Your role cannot archive plans. Owners and managers only." };
  }

  revalidatePath("/plans");
  revalidatePath(`/plans/${id}`);
  return null;
}

export async function deletePlan(_prev: PlanFormState, fd: FormData): Promise<PlanFormState> {
  const ctx = await getStaffContext();
  if (!ctx) return { error: "Not signed in." };

  const id = String(fd.get("id") ?? "");
  const supabase = createClient();
  const { data, error } = await supabase
    .from("membership_plans")
    .delete()
    .eq("id", id)
    .select("id");

  if (error) {
    // PT409 from guard_plan_delete(): the plan has members on it. The database
    // is the thing that knows, and it refuses on every path, not just this one.
    if (error.code === "PT409") return { error: error.message };
    return { error: error.message };
  }
  if (!data || data.length === 0) {
    return { error: "Your role cannot delete plans. Owners and managers only." };
  }

  revalidatePath("/plans");
  redirect("/plans");
}
