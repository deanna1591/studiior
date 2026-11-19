import Link from "next/link";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { formatMoney } from "@/lib/plans";
import PrivateFlow from "./flow";

export const dynamic = "force-dynamic";

/**
 * Decision 116: book a private session. Pick a type, a coach or any coach, a time
 * from the free gaps only (private_slots), the companions for a Duo or Trio, then
 * pay through Xendit or with a 1:1 pack credit. The session is hidden from every
 * other member and the public timetable.
 */
export default async function BookPrivate() {
  const { ctx, supabase, settings, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const [{ data: types }, { data: coaches }] = await Promise.all([
    supabase.rpc("private_session_types_for", { p_studio_id: ctx.studioId }),
    supabase.from("instructors").select("id, display_name, avatar_url")
      .eq("studio_id", ctx.studioId).eq("status", "active").eq("teaches_privates", true).order("display_name"),
  ]);
  const list = (types ?? []) as { id: string; name: string; price_cents: number; people: number; duration_min: number }[];

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href="/book" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Book
      </Link>
      <h1 className="m-title mb-1 text-ink">Private sessions</h1>
      <p className="m-sub mb-4 text-ink-2">
        A session just for you, or you and one or two friends, at a time the studio is free.
      </p>
      {!settings.privateSessionsEnabled || list.length === 0 ? (
        <div className="m-card px-4 py-5">
          <p className="m-body text-ink-2">{studioName} isn&apos;t offering private sessions right now.</p>
        </div>
      ) : (
        <PrivateFlow
          types={list.map((t) => ({ ...t, priceLabel: formatMoney(t.price_cents, settings.currency) }))}
          coaches={(coaches ?? []).map((c) => ({ id: c.id as string, name: (c.display_name as string).split(" ")[0] }))}
          timeZone={ctx.timeZone} timeFormat={ctx.timeFormat}
          packCredits={settings.privatePackCredits}
          creditCents={settings.reservationCreditCents}
        />
      )}
    </MemberShell>
  );
}
