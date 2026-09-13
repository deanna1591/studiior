import Link from "next/link";
import Avatar from "@/components/member/avatar";
import { Icon } from "@/components/member/icons";
import { memberScreen } from "@/lib/member";
import MemberShell from "@/components/member/shell";
import { SignOut } from "@/components/member/sign-out";

export const dynamic = "force-dynamic";

/**
 * Account is a hub, not a wall — a list that leads somewhere. The person at the
 * top, then each thing they might want on its own screen. The tab bar stays at
 * five; everything here hangs off this one tab.
 */
export default async function Account() {
  const { studioName, logoUrl, preset, accent, openOffers, memberName, avatarUrl } =
    await memberScreen();

  const rows: { href: string; label: string; sub: string }[] = [
    { href: "/account/classes", label: "Your classes", sub: "Every class you have booked, and what happened" },
    { href: "/account/plan", label: "Your plan", sub: "Membership, credits, guest passes and peak classes" },
    { href: "/account/payments", label: "Payments", sub: "What you have paid, and for what" },
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

      <SignOut to="/login"
               className="m-tap m-card mt-6 w-full text-[14px] font-semibold text-ink-2">
        Sign out
      </SignOut>
    </MemberShell>
  );
}
