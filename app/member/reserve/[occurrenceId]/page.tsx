import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { formatMoney } from "@/lib/plans";
import { payeeNoticeLine } from "@/lib/payee-notice";
import ReserveBody from "./reserve-body";

export const dynamic = "force-dynamic";

/**
 * Decision 103 — the reservation checkout. A first-timer books their free class
 * when the studio charges a reservation fee: the class card, the wording rule,
 * the payee notice, and Continue to pay. The seat is held as pending_payment and
 * the webhook completes the comp free seat after the fee is paid.
 */
export default async function Reserve({ params }: { params: { occurrenceId: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, settings, openOffers, memberName, avatarUrl } =
    await memberScreen();
  const occId = params.occurrenceId;

  // No fee -> this screen does not apply; the ordinary free booking is on /book.
  if ((settings.reservationFeeCents ?? 0) <= 0) redirect(`/class/${occId}`);

  const { data: occ } = await supabase.from("class_occurrences")
    .select("id, name, starts_at, ends_at, status, instructors!instructor_id(display_name)")
    .eq("id", occId).maybeSingle();
  if (!occ || occ.status !== "scheduled") notFound();

  const feeLabel = formatMoney(settings.reservationFeeCents, settings.currency);
  const instructor = (occ as { instructors: { display_name: string } | null }).instructors;
  const instructorFirst = instructor?.display_name?.split(" ")[0] ?? null;
  const whenLabel = `${fmtDayLong(occ.starts_at, ctx.timeZone)} · ${fmtTime(occ.starts_at, ctx.timeZone, ctx.timeFormat)}${occ.ends_at ? `–${fmtTime(occ.ends_at, ctx.timeZone, ctx.timeFormat)}` : ""}`;
  const payeeLine = payeeNoticeLine(studioName, settings.payeeNoticeName);

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent}>
      <Link href={`/class/${occId}`} className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
        <Icon name="chevron-left" size={16} /> Class
      </Link>
      <h1 className="m-title mb-4 text-ink">Reserve your free class</h1>

      <div className="mb-4 rounded-2xl bg-surface px-3.5 py-3"
           style={{ boxShadow: "0 1px 3px rgb(26 21 18 / 0.06)" }}>
        <div className="m-body font-semibold text-ink">{occ.name}</div>
        <div className="m-micro mt-0.5 text-ink-3">
          {[whenLabel, instructorFirst].filter(Boolean).join(" · ")}
        </div>
      </div>

      <p className="m-sub mb-4 text-[13px] leading-[19px] text-ink-2">
        This is a reservation fee, not a charge for the class. Show up and the {feeLabel} is
        credited back to your account to use on class packages or merchandise. If you don&rsquo;t
        show up or cancel late, the fee is not refunded.
      </p>

      {payeeLine && <p className="m-micro mb-4 text-ink-3">{payeeLine}</p>}

      <ReserveBody occId={occId} feeLabel={feeLabel} />
    </MemberShell>
  );
}
