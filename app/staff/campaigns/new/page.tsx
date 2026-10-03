import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import { createCampaign } from "../actions";

export const dynamic = "force-dynamic";

/**
 * A deliberate one-click start, rather than creating an empty draft on every
 * GET of /campaigns/new. The button posts createCampaign, which inserts the
 * draft and redirects into its editor.
 */
export default async function NewCampaign() {
  const screen = await staffScreen("/campaigns/new");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="New campaign"><Denied what="campaigns" role={ctx.role} /></AppShell>;
  }

  return (
    <AppShell {...shell} title="New campaign"
      actions={<Link href="/campaigns" className="text-[13px] text-ink-2 underline underline-offset-4">All campaigns</Link>}>
      <p className="mb-4 max-w-[60ch] text-[13px] leading-5 text-ink-2">
        Start a draft — you write the subject and message, choose who it goes to,
        preview it and send a test before anything leaves the studio.
      </p>
      <form action={createCampaign}>
        <button type="submit"
          className="inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] text-paper hover:bg-ink-2">
          Start a campaign
        </button>
      </form>
    </AppShell>
  );
}
