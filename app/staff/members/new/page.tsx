import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import NewMemberForm from "./form";

export const dynamic = "force-dynamic";

export default async function NewMember() {
  const screen = await staffScreen("/members/new");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;

  // Permissions §5: Owner, Manager and Front Desk. The person at the counter is
  // exactly who signs a walk-in up, so instructors are the only ones refused.
  if (!["owner", "manager", "front_desk"].includes(ctx.role)) {
    return (
      <AppShell {...shell} title="Add a member">
        <Denied what="Adding members" role={ctx.role} />
      </AppShell>
    );
  }

  return (
    <AppShell {...shell} title="Add a member"
              actions={<NavLink href="/members">Back to members</NavLink>}>
      <p className="mb-5 max-w-[58ch] text-[13px] leading-[20px] text-ink-2">
        For somebody signing up at the counter. Adding them here does not send
        them anything — you invite them to the app from their own screen once
        they are in, or all at once from{" "}
        <NavLink href="/members/invites">Invites</NavLink>.
      </p>
      <NewMemberForm />
    </AppShell>
  );
}
