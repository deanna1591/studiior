import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import SchedulePosts from "@/components/staff/schedule-post";
import { defaultSpec, type BrandSpec } from "@/lib/brand-kit";
import type { PostStyle } from "@/lib/schedule-post";
import {
  instructorSchedulePostData, instructorUploadPostImage, instructorSignPostImage,
} from "../actions";

export const dynamic = "force-dynamic";

/**
 * Decision 93 part (c): an instructor's own Posts page.
 *
 * It reuses the one Schedule-posts component (components/staff/schedule-post.tsx)
 * with the coach LOCKED to the signed-in instructor and the Claude edit box
 * HIDDEN. The data comes from instructor_schedule_post_data (the caller's own
 * classes, resolved from auth) and the look from instructor_brand_kit (the
 * studio's current kit, read-only). There is no coach picker, no brand-kit
 * change, no footer/hashtag settings — those belong to the studio.
 */
export default async function InstructorPostsPage() {
  const { ctx, supabase } = await instructorScreen();
  const [{ data: kit }, { data: settings }] = await Promise.all([
    supabase.rpc("instructor_brand_kit"),
    supabase.from("studio_settings").select("flex_min_bookings").eq("studio_id", ctx.studio_id).maybeSingle(),
  ]);
  const k = (kit ?? {}) as { spec?: BrandSpec; post_style?: string };
  const spec = k.spec ?? defaultSpec({ accent: ctx.accent_color ?? undefined, themePreset: ctx.theme_preset ?? undefined });
  const initialStyle = (k.post_style ?? "invitation") as PostStyle;
  const todayIso = new Date().toLocaleDateString("en-CA", { timeZone: ctx.timezone }); // studio-local YYYY-MM-DD
  const flexMin = settings?.flex_min_bookings ?? 1;
  const first = (ctx.display_name ?? "").trim().split(/\s+/)[0] || (ctx.display_name ?? "");

  return (
    <InstructorShell ctx={ctx} title="Marketing">
      <Link href="/instructor" className="m-sub mb-3 inline-flex items-center gap-1 text-ink-3">← Home</Link>
      <p className="m-sub mb-4 text-ink-2">
        Make a post of your own classes in your studio&rsquo;s look, then share it. Hidden classes never appear.
      </p>
      <SchedulePosts
        spec={spec}
        studioName={ctx.studio_name}
        studioId={ctx.studio_id}
        todayIso={todayIso}
        flexMin={flexMin}
        canEdit={false}
        editUsed={0}
        editCap={0}
        initialStyle={initialStyle}
        coaches={[]}
        loadPostData={instructorSchedulePostData}
        signImage={instructorSignPostImage}
        uploadImage={instructorUploadPostImage}
        onPickStyle={null}
        lockedCoach={{ id: ctx.instructor_id, first }}
        hideEdit
      />
    </InstructorShell>
  );
}
