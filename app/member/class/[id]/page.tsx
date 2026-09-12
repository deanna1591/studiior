import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import ClassDetailBody from "@/components/member/class-detail-body";
import { loadClassDetail } from "./load";

export const dynamic = "force-dynamic";

/**
 * One class, in full — the full-page form, reached by a direct load, a refresh
 * or a deep link. A tap from inside the app is intercepted and shown as a
 * bottom sheet instead (app/member/@modal/(.)class/[id]); both render the same
 * ClassDetailBody, so they cannot drift.
 */
export default async function ClassDetail({ params }: { params: { id: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const data = await loadClassDetail(supabase, ctx.memberId, params.id);
  if (!data) notFound();

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/book" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> All classes
      </Link>

      <ClassDetailBody occ={data.occ} type={data.type} booking={data.booking}
                       timeZone={ctx.timeZone} waitlistEnabled={settings.waitlistEnabled} />
    </MemberShell>
  );
}
