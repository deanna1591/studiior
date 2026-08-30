import { getStaffAccess, requireOnboarded, isManagerUp } from "@/lib/auth";
import StaffAccessGate from "@/components/staff-access-gate";
import { Shell, NavLink } from "@/components/ui";
import UploadForm from "./upload-form";

export const dynamic = "force-dynamic";

export default async function NewImport() {
  const access = await getStaffAccess();
  if (access.kind !== "staff") return <StaffAccessGate access={access} />;
  const ctx = requireOnboarded(access.ctx);

  if (!isManagerUp(ctx.role)) {
    return (
      <Shell title="New import" subtitle={ctx.studioName} right={<NavLink href="/">Back to week</NavLink>}>
        <p className="text-sm text-ink-2">Importing is owners and managers.</p>
      </Shell>
    );
  }

  return (
    <Shell title="New import" subtitle={ctx.studioName}
           right={<NavLink href="/imports">All imports</NavLink>}>
      <UploadForm />
    </Shell>
  );
}
