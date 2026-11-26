import Link from "next/link";
import { notFound } from "next/navigation";
import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, SectionLabel } from "@/components/ui";
import CodeRows, { type CodeRow } from "./rows";

export const dynamic = "force-dynamic";

/** Decision 120: one batch's codes (or a shared code's uses), with their state. */
export default async function CodeBatch({ params }: { params: { id: string } }) {
  const screen = await staffScreen("/settings");
  if (screen.gate) return screen.gate;
  const { ctx, supabase, shell } = screen;
  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Discount codes"><Denied what="discount codes" role={ctx.role} /></AppShell>;
  }
  const { data: batch } = await supabase.from("discount_code_batches")
    .select("id, kind, name, pct, starts_on, ends_on, max_uses").eq("id", params.id).maybeSingle();
  if (!batch) notFound();
  const { data: rows } = await supabase.rpc("discount_code_rows", { p_batch_id: params.id });
  return (
    <AppShell {...shell} title="Discount codes">
      <Link href="/settings/promotions/codes" className="mb-3 inline-block text-[13px] text-ink-2 underline underline-offset-4">← Discount codes</Link>
      <SectionLabel>{batch.name}</SectionLabel>
      <p className="mb-4 mt-2 text-[13px] text-ink-2">
        {batch.pct}% off · {batch.kind === "batch" ? "unique single-use codes" : `shared code, up to ${batch.max_uses} uses, once per person`}
        {" · "}{batch.starts_on} to {batch.ends_on}
      </p>
      <CodeRows batchId={batch.id} kind={batch.kind as "batch" | "shared"} rows={(rows ?? []) as CodeRow[]} timeZone={ctx.timeZone} />
    </AppShell>
  );
}
