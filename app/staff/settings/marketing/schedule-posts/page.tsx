import { staffScreen } from "@/lib/screen";
import { isDeskUp, isManagerUp } from "@/lib/auth";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import SettingsBack from "../../back";
import SchedulePosts from "@/components/staff/schedule-post";
import { defaultSpec, type BrandSpec } from "@/lib/brand-kit";
import type { PostStyle } from "@/lib/schedule-post";

export const dynamic = "force-dynamic";

/**
 * Settings → Marketing → Schedule posts (Decision 93 slice 2). Desk-up may make
 * posts (front desk too). The post renders client-side from the studio's current
 * brand kit + schedule_post_data; Download PNG exports at full size and saves a
 * copy to post-images; Copy caption copies the classes + hashtags.
 */
export default async function SchedulePostsPage() {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isDeskUp(ctx.role)) {
    return <AppShell {...shell} title="Schedule posts"><Denied what="Schedule posts" role={ctx.role} /></AppShell>;
  }

  const [{ data: cur }, { data: studio }, { data: settings }, { data: instructors }] = await Promise.all([
    supabase.rpc("brand_kit_current", { p_studio_id: ctx.studioId }),
    supabase.from("studios").select("timezone, accent_color, theme_preset").eq("id", ctx.studioId).maybeSingle(),
    supabase.from("studio_settings")
      .select("flex_min_bookings, post_edit_runs_month, post_edit_runs_reset_on, post_style")
      .eq("studio_id", ctx.studioId).maybeSingle(),
    supabase.from("instructors").select("id, display_name")
      .eq("studio_id", ctx.studioId).eq("status", "active").order("display_name"),
  ]);
  const row = (cur ?? {}) as { spec?: BrandSpec };
  const spec = row.spec ?? defaultSpec({ accent: studio?.accent_color ?? undefined, themePreset: studio?.theme_preset ?? undefined });
  const tz = studio?.timezone ?? "UTC";
  const todayIso = new Date().toLocaleDateString("en-CA", { timeZone: tz }); // YYYY-MM-DD, studio-local
  const flexMin = settings?.flex_min_bookings ?? 1;
  const initialStyle = (settings?.post_style ?? "invitation") as PostStyle;
  const coaches = (instructors ?? []).map((i) => ({
    id: i.id, first: (i.display_name ?? "").trim().split(/\s+/)[0] || (i.display_name ?? ""),
  }));
  // The month's post-edit count (resets on the first of the studio-local month).
  const resetOn = settings?.post_edit_runs_reset_on ?? null;
  const editUsed = resetOn && todayIso < resetOn ? (settings?.post_edit_runs_month ?? 0) : 0;
  const editCap = 60;

  return (
    <AppShell {...shell} title="Schedule posts">
      <SettingsBack />
      <SectionLabel>Schedule posts</SectionLabel>
      <p className="mt-2 max-w-2xl text-[13px] leading-[19px] text-ink-2">
        Make a social post of your timetable in your studio&rsquo;s look. Pick a day, week or month,
        download the image and copy the caption. Hidden classes never appear.
      </p>
      <div className="mt-4 max-w-4xl">
        <SchedulePosts
          spec={spec}
          studioName={ctx.studioName}
          todayIso={todayIso}
          flexMin={flexMin}
          canEdit={isManagerUp(ctx.role)}
          editUsed={editUsed}
          editCap={editCap}
          initialStyle={initialStyle}
          coaches={coaches}
        />
      </div>
    </AppShell>
  );
}
