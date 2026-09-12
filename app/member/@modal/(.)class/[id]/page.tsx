import { memberScreen } from "@/lib/member";
import Sheet from "@/components/member/sheet";
import ClassDetailBody from "@/components/member/class-detail-body";
import { loadClassDetail } from "@/app/member/class/[id]/load";

export const dynamic = "force-dynamic";

/**
 * A class tapped from inside the app, shown as a bottom sheet rather than a new
 * page. This route INTERCEPTS `/class/[id]` — the (.) means "same segment
 * level" — so the tap changes the URL and opens the sheet while the page behind
 * it stays put. A refresh or a shared link does not match the interceptor and
 * falls through to the full page.
 *
 * Same loader and same body as the page: one query, one presentation, no drift.
 */
export default async function ClassSheet({ params }: { params: { id: string } }) {
  const { ctx, supabase, settings, preset, accent } = await memberScreen();
  const data = await loadClassDetail(supabase, ctx.memberId, params.id);
  // Not found or not visible: show no sheet rather than an empty one. The
  // address bar still reads /class/[id]; a back step closes it.
  if (!data) return null;

  return (
    <Sheet preset={preset} accent={accent}>
      <ClassDetailBody occ={data.occ} type={data.type} booking={data.booking}
                       timeZone={ctx.timeZone} waitlistEnabled={settings.waitlistEnabled} />
    </Sheet>
  );
}
