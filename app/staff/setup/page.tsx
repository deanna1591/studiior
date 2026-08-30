import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Empty } from "@/components/ui";
import SetupChecklist from "../setup-checklist/checklist";

export const dynamic = "force-dynamic";

export default async function Setup() {
  const screen = await staffScreen("/setup");
  if (screen.gate) return screen.gate;
  const { ctx, shell, summary } = screen;

  const page = (children: React.ReactNode) => (
    <AppShell
      {...shell}
      title="Setup"
    >
      {children}
    </AppShell>
  );

  if (!isManagerUp(ctx.role)) {
    return page(
      <Empty>Setting up the studio is for owners and managers. Ask yours to finish it.</Empty>,
    );
  }

  return page(
    <>
      <p className="mb-5 max-w-[54ch] text-[13px] leading-[20px] text-ink-2">
        Every tick comes from your actual data, not from a box someone once
        checked — delete your last room and that step comes back. Do them in any
        order, and skip the ones that will never apply to you.
      </p>
      {summary.complete ? (
        <Empty>
          You are set up. Nothing left on the list — this page will stay here if
          you ever need to check.
        </Empty>
      ) : (
        <SetupChecklist state={summary.state} />
      )}
    </>,
  );
}
