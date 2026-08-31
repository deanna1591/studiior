import { isManagerUp } from "@/lib/auth";
import { staffScreen } from "@/lib/screen";
import { AppShell, Denied, NavLink } from "@/components/ui";
import UploadForm from "./upload-form";

export const dynamic = "force-dynamic";

export default async function NewImport() {
  const screen = await staffScreen("/imports/new");
  if (screen.gate) return screen.gate;
  const { ctx, shell } = screen;

  if (!isManagerUp(ctx.role)) {
    return <AppShell {...shell} title="Import"><Denied what="Importing" role={ctx.role} /></AppShell>;
  }

  return (
    <AppShell {...shell} title="New import"
              actions={<NavLink href="/imports">All imports</NavLink>}>
      <UploadForm />
    </AppShell>
  );
}
