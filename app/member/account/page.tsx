import Link from "next/link";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import { memberScreen, membershipState } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { SignOut } from "@/components/member/sign-out";
import { formatMoney } from "@/lib/plans";

export const dynamic = "force-dynamic";

/**
 * Account is a hub — a list that leads somewhere. But the one thing a member
 * opens Account to check is usually their plan and credits, so that glance sits
 * at the top (a tap to /account/plan for the detail), and the list is below.
 * Making it a hub must not turn a one-tap "what are my credits" into two.
 */
export default async function Account() {
  const { ctx, supabase, studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl, settings } =
    await memberScreen();
  // Decision 82: membershipState joins the same wave (it depends on nothing in
  // it), so Account is one round trip after the context rather than two.
  // Decision 63: the Shop entry appears only when the studio has products, and
  // My orders only when this member has ordered something.
  const [membership, { data: shop }, { data: orders }, { data: aiDrafts }, { data: credits }, { data: creditPays }] = await Promise.all([
    membershipState(supabase, ctx.memberId),
    supabase.rpc("member_shop", { p_studio_id: ctx.studioId }),
    supabase.rpc("member_orders"),
    supabase.rpc("member_sees_ai_drafts"),
    // Decision 110(a): the Credits card — each credit received (own rows, RLS)
    // and each purchase credit paid for (source credit, own payments).
    supabase.from("member_credits").select("id, amount_cents, used_cents, currency, reason, created_at, voided_at")
      .eq("member_id", ctx.memberId).order("created_at", { ascending: false }).limit(20),
    supabase.from("payments").select("id, amount_cents, currency, description, paid_at, created_at")
      .eq("member_id", ctx.memberId).eq("source", "credit").order("created_at", { ascending: false }).limit(10),
  ]);
  const creditRows = (credits ?? []).filter((c) => !c.voided_at);
  const giftLeft = settings.giftCreditCents;
  const otherLeft = Math.max(0, settings.reservationCreditCents - settings.giftCreditCents);
  const creditWord = (r: string) => r === "gift_credit" ? "Gift card"
    : r === "private_refund" ? "Private session returned"
    : r.startsWith("reservation") ? "Reservation fee returned" : "Credit";
  const dShort = (iso: string) => new Intl.DateTimeFormat("en-GB", { timeZone: ctx.timeZone, day: "numeric", month: "short" }).format(new Date(iso));
  const history = [
    ...creditRows.map((c) => ({ at: c.created_at as string, line: `${creditWord(c.reason as string)} · received`, amt: `+${formatMoney(c.amount_cents as number, (c.currency as string) ?? settings.currency)}` })),
    ...(creditPays ?? []).map((p) => ({ at: (p.paid_at ?? p.created_at) as string, line: `Used on ${p.description ?? "a purchase"}`, amt: `−${formatMoney(p.amount_cents as number, (p.currency as string) ?? settings.currency)}` })),
  ].sort((a, b) => b.at.localeCompare(a.at)).slice(0, 8);
  const { live } = membership;
  const hasProducts = Array.isArray(shop) && shop.length > 0;
  const hasOrders = Array.isArray(orders) && orders.length > 0;

  const rows: { href: string; label: string; sub: string }[] = [
    { href: "/account/classes", label: "Your classes", sub: "Every class you have booked, and what happened" },
    { href: "/account/plan", label: "Your plan", sub: "Membership, credits, guest passes and peak classes" },
    // Decision 110: anyone can have a gift code; the redeem screen is always here.
    { href: "/account/redeem", label: "Redeem a gift card", sub: "Have a gift code? Add its credit to your account" },
    ...(hasProducts ? [{ href: "/shop", label: "Shop", sub: "Things the studio sells, picked up at the front desk" }] : []),
    ...(hasOrders ? [{ href: "/account/orders", label: "My orders", sub: "What you have bought, and whether it is ready" }] : []),
    // Decision 89: only when the studio has turned messages on.
    ...(settings.messagesEnabled ? [{ href: "/messages", label: "Message the studio", sub: "Ask about your bookings, plans or anything else" }] : []),
    // Decision 88(c): one home for everything bought — plans, payments, invoices.
    { href: "/purchases", label: "My purchases", sub: "Your plans, payments and invoices" },
    { href: "/account/pay", label: "How you pay", sub: "Your cards, or how the studio takes payment" },
    { href: "/account/profile", label: "Your details", sub: "Name, photo, phone, emergency contact" },
    { href: "/settings", label: "Notifications", sub: "Which emails you get" },
  ];

  return (
    <MemberShell openOffers={openOffers} memberName={memberName} avatarUrl={avatarUrl}
                 studioName={studioName} logoUrl={logoUrl} preset={preset} accent={accent} title="Account">
      <div className="mb-5 flex items-center gap-4">
        <Avatar name={memberName || studioName} url={avatarUrl} size={56} />
        <span className="m-title text-ink">{memberName || "You"}</span>
      </div>

      {/* The glance: plan and credits, the reason most people open Account. Tap
          through for the full plan. Absent (not empty) with no plan. */}
      {live && (
        <Link href="/account/plan" className="m-card m-press mb-4 flex items-center gap-3 p-4">
          <span className="min-w-0 flex-1">
            <span className="m-name block text-ink">{live.membership_plans?.name}</span>
            <span className="m-sub block text-ink-2">
              {live.membership_plans?.type === "recurring" && live.credits_remaining === null
                ? "Unlimited classes"
                : <><span className="num font-semibold text-ink">{live.credits_remaining ?? 0}</span> classes left</>}
              {live.status !== "active" && <> · {live.status.replace("_", " ")}</>}
            </span>
          </span>
          <Icon name="chevron-right" size={18} className="shrink-0 text-ink-3" />
        </Link>
      )}

      {/* Decision 110(a): Credits — gift credit named apart from reservation and
          refund credit, with what came in and what it paid for. Absent when none. */}
      {(settings.reservationCreditCents > 0 || history.length > 0) && (
        <div className="m-card mb-4 px-4 py-4">
          <p className="m-name text-ink">Credits</p>
          <div className="mt-2 grid grid-cols-2 gap-2">
            <div className="rounded-xl px-3 py-2" style={{ background: "var(--accent-chip)" }}>
              <span className="m-micro block text-ink-2">Gift credit</span>
              <span className="m-body num font-semibold text-ink">{formatMoney(giftLeft, settings.currency)}</span>
            </div>
            <div className="rounded-xl px-3 py-2" style={{ background: "var(--accent-chip)" }}>
              <span className="m-micro block text-ink-2">Reservation and returned</span>
              <span className="m-body num font-semibold text-ink">{formatMoney(otherLeft, settings.currency)}</span>
            </div>
          </div>
          <p className="m-micro mt-2 text-ink-2">Used at checkout before any payment. Gift credit never expires.</p>
          {history.length > 0 && (
            <ul className="mt-3 divide-y divide-line">
              {history.map((h, i) => (
                <li key={i} className="flex items-center justify-between py-2">
                  <span className="m-sub text-ink">{h.line}<span className="text-ink-2"> · {dShort(h.at)}</span></span>
                  <span className="m-sub num text-ink">{h.amt}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      <ul className="m-card divide-y divide-line overflow-hidden">
        {rows.map((r) => (
          <li key={r.href}>
            <Link href={r.href} className="m-press flex items-center gap-3 px-4 py-3.5">
              <span className="min-w-0 flex-1">
                <span className="m-body block font-semibold text-ink">{r.label}</span>
                <span className="m-micro block text-ink-3">{r.sub}</span>
              </span>
              <Icon name="chevron-right" size={18} className="shrink-0 text-ink-3" />
            </Link>
          </li>
        ))}
      </ul>

      {aiDrafts === true && (
        <p className="m-micro mt-4 px-1 text-ink-3">
          To write you a personal note, {studioName} may use an AI assistant that sees your first
          name, class history and plan — a person always reads and sends it.
        </p>
      )}

      <SignOut to="/login"
               className="m-tap m-card mt-6 w-full text-[14px] font-semibold text-ink-2">
        Sign out
      </SignOut>
    </MemberShell>
  );
}
