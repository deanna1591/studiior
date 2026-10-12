import Link from "next/link";
import { notFound } from "next/navigation";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { Icon } from "@/components/member/icons";
import { fmtTime, dayMonthParts } from "@/lib/time";
import { eligibleGroupClasses } from "@/lib/group";
import { EmailsForm, SwapForm, CancelGroupForm } from "./forms";

export const dynamic = "force-dynamic";

/**
 * Decision 76b — the member's group (Barkada) booking flow and host view.
 *  unbooked, no ?occ  → "Pick your class" (classes with room for the group).
 *  unbooked, ?occ=…   → the emails screen (group_size − 1 fields) → book_group.
 *  booked             → the class, all names, Swap per guest, Cancel group.
 *  expired/cancelled  → a short note.
 * RLS shows a group_purchases row only to its host, so a non-host 404s.
 */
export default async function GroupBooking({
  params, searchParams,
}: { params: { id: string }; searchParams: { occ?: string } }) {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const { data: gp } = await supabase
    .from("group_purchases")
    .select("id, status, group_size, expires_on, occurrence_id, host_member_id, membership_plans(name, restrictions)")
    .eq("id", params.id).maybeSingle();
  if (!gp || gp.host_member_id !== ctx.memberId) notFound();

  const plan = gp.membership_plans as unknown as { name: string; restrictions: { class_type_ids?: string[] } | null } | null;
  const planName = plan?.name ?? "Group package";
  const restrict = plan?.restrictions?.class_type_ids ?? [];

  const { data: me } = await supabase.from("members").select("email").eq("id", ctx.memberId).maybeSingle();
  const hostEmail = me?.email ?? "";

  const byDate = new Intl.DateTimeFormat("en-GB",
    { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(new Date(`${gp.expires_on}T00:00:00Z`));
  const when = (iso: string) => {
    const { day, month } = dayMonthParts(iso, ctx.timeZone);
    return `${day} ${month} · ${fmtTime(iso, ctx.timeZone, ctx.timeFormat)}`;
  };

  const shell = { openOffers, memberName, avatarUrl, studioName, logoUrl, preset, accent };
  const Back = (
    <Link href="/account" className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
      <Icon name="chevron-left" size={16} /> Account
    </Link>
  );

  // ---- Terminal states ----------------------------------------------------
  if (gp.status === "expired" || gp.status === "cancelled") {
    return (
      <MemberShell {...shell}>
        {Back}
        <h1 className="m-title mb-4 text-ink">{planName}</h1>
        <div className="m-card p-5 text-center">
          <p className="text-[16px] font-semibold text-ink">
            {gp.status === "expired" ? "This group wasn’t booked in time" : "This group was cancelled"}
          </p>
          <p className="m-sub mt-1 text-ink-2">
            {gp.status === "expired"
              ? "The window to pick a class has passed. Ask the studio if you’d still like to use it."
              : "Nothing is booked. Ask the studio if you’d like to arrange another."}
          </p>
        </div>
      </MemberShell>
    );
  }

  // ---- Booked: the host view ----------------------------------------------
  if (gp.status === "booked" && gp.occurrence_id) {
    const [{ data: occ }, { data: seats }] = await Promise.all([
      supabase.from("class_occurrences").select("id, name, starts_at").eq("id", gp.occurrence_id).maybeSingle(),
      supabase.from("group_bookings")
        .select("is_host, members(first_name, last_name, email)")
        .eq("group_purchase_id", gp.id),
    ]);
    const rows = (seats ?? []).map((s) => {
      const m = s.members as unknown as { first_name: string | null; last_name: string | null; email: string | null } | null;
      return { isHost: s.is_host as boolean,
               name: `${m?.first_name ?? ""} ${m?.last_name ?? ""}`.trim() || (m?.email ?? "Guest"),
               email: m?.email ?? "" };
    }).sort((a, b) => (a.isHost === b.isHost ? 0 : a.isHost ? -1 : 1));

    return (
      <MemberShell {...shell}>
        {Back}
        <h1 className="m-title mb-1 text-ink">{planName}</h1>
        {occ && (
          <p className="m-sub mb-4 text-ink-2">
            {occ.name} · <span className="num">{when(occ.starts_at)}</span>
          </p>
        )}
        <section className="m-card p-4">
          <p className="m-micro text-ink-3">Your group</p>
          <ul className="mt-2 divide-y divide-line">
            {rows.map((r, i) => (
              <li key={i} className="flex items-center justify-between gap-3 py-2.5">
                <span className="min-w-0">
                  <span className="block text-[14px] leading-5 text-ink">{r.name}</span>
                  {r.isHost
                    ? <span className="m-micro text-ink-3">You · seat 1</span>
                    : <span className="m-micro text-ink-3">{r.email}</span>}
                </span>
                {!r.isHost && <SwapForm groupId={gp.id} oldEmail={r.email} />}
              </li>
            ))}
          </ul>
        </section>
        <div className="mt-2">
          <CancelGroupForm groupId={gp.id} late={false} />
          <p className="m-micro mt-1 text-ink-3">
            You can swap a guest or cancel the whole group up to the studio’s cancellation cut-off.
          </p>
        </div>
      </MemberShell>
    );
  }

  // ---- Unbooked + a class chosen: the emails screen ------------------------
  if (searchParams.occ) {
    const { data: occ } = await supabase
      .from("class_occurrences").select("id, name, starts_at").eq("id", searchParams.occ).maybeSingle();
    return (
      <MemberShell {...shell}>
        <Link href={`/group/${gp.id}`} className="m-sub m-press mb-3 inline-flex items-center gap-1 text-ink-2">
          <Icon name="chevron-left" size={16} /> Pick another class
        </Link>
        <h1 className="m-title mb-1 text-ink">Who&rsquo;s coming?</h1>
        {occ && <p className="m-sub mb-4 text-ink-2">{occ.name} · <span className="num">{when(occ.starts_at)}</span></p>}
        <p className="m-sub mb-3 text-ink-2">
          You&rsquo;re seat one. Add the {gp.group_size - 1} {gp.group_size - 1 === 1 ? "person" : "people"} coming with you —
          we&rsquo;ll email anyone who isn&rsquo;t a member yet to set up their account and sign the waiver.
        </p>
        <EmailsForm groupId={gp.id} occId={searchParams.occ} hostEmail={hostEmail}
                    groupSize={gp.group_size} doneHref={`/group/${gp.id}`} />
      </MemberShell>
    );
  }

  // ---- Unbooked, no class yet: pick your class -----------------------------
  const nowMs = Date.now();
  const { data: classes } = await supabase
    .from("class_occurrences")
    .select("id, name, starts_at, status, capacity, booked_count, class_type_id")
    .eq("studio_id", ctx.studioId).eq("status", "scheduled")
    .gte("starts_at", new Date(nowMs).toISOString())
    .order("starts_at").limit(200);
  const typed = (classes ?? []).map((c) => ({ ...c, occurrence_id: c.id }));
  const restricted = restrict.length > 0
    ? typed.filter((c) => c.class_type_id && restrict.includes(c.class_type_id))
    : typed;
  const eligible = eligibleGroupClasses(restricted, gp.group_size, nowMs);

  return (
    <MemberShell {...shell}>
      {Back}
      <h1 className="m-title mb-1 text-ink">Pick your class</h1>
      <p className="m-sub mb-1 text-ink-2">
        {planName} · a group of <span className="num">{gp.group_size}</span>. Pick any class with room for everyone.
      </p>
      <p className="m-sub mb-4 text-ink-3">Book by <span className="num">{byDate}</span>.</p>

      {eligible.length === 0 ? (
        <div className="m-card p-5 text-center">
          <p className="m-body text-ink">No class has room for all {gp.group_size} of you right now.</p>
          <p className="m-sub mt-1 text-ink-2">Check back, or ask the studio.</p>
        </div>
      ) : (
        <ul className="space-y-2">
          {eligible.map((c) => {
            const free = c.capacity - c.booked_count;
            return (
              <li key={c.id}>
                <Link href={`/group/${gp.id}?occ=${c.id}`}
                      className="m-card m-press flex items-center justify-between gap-3 p-4">
                  <span className="min-w-0">
                    <span className="block text-[15px] font-semibold leading-5 text-ink">{c.name}</span>
                    <span className="m-sub block text-ink-2"><span className="num">{when(c.starts_at)}</span></span>
                  </span>
                  <span className="m-sub shrink-0 text-ink-3"><span className="num">{free}</span> free</span>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </MemberShell>
  );
}
