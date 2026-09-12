import Link from "next/link";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied } from "@/components/ui";
import ChallengeForm from "../form";

export const dynamic = "force-dynamic";

export default async function NewChallenge() {
  const screen = await staffScreen("/challenges");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="New challenge"><Denied what="Challenges" role={ctx.role} /></AppShell>;
  }

  const [{ data: templates }, { data: types }] = await Promise.all([
    // System templates (studio_id null) plus any the studio has saved.
    supabase.from("challenge_templates")
      .select("id, title, type, goal_value, duration_days, description, reward_description")
      .eq("audience", "member").order("title"),
    supabase.from("class_types").select("id, name").eq("status", "active").order("name"),
  ]);

  const today = new Date().toISOString().slice(0, 10);

  return (
    <AppShell {...shell} title="New challenge">
      <Link href="/challenges" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">
        ← All challenges
      </Link>
      <ChallengeForm templates={templates ?? []} classTypes={types ?? []} today={today} />
    </AppShell>
  );
}
