export const TYPE_LABEL: Record<string, string> = {
  members: "Members",
  memberships: "Memberships",
  attendance: "Attendance",
};

export const STATUS_LABEL: Record<string, string> = {
  uploaded: "Needs mapping",
  validating: "Checking",
  dry_run_complete: "Reviewed, not imported",
  importing: "Importing",
  complete: "Imported",
  failed: "Failed",
  rolled_back: "Rolled back",
};

const TONE: Record<string, string> = {
  uploaded: "bg-amber-tint text-ink border-amber",
  dry_run_complete: "bg-paper text-ink-2 border-line-2",
  complete: "bg-lime-tint text-lime-text border-lime-text",
  failed: "bg-coral-tint text-ink border-coral",
  rolled_back: "bg-line text-ink-2 border-line-2",
};

export function StatusPill({ status }: { status: string }) {
  return (
    <span className={`shrink-0 rounded border px-2 py-0.5 text-xs ${
      TONE[status] ?? "bg-line text-ink-2 border-line-2"}`}>
      {STATUS_LABEL[status] ?? status}
    </span>
  );
}
