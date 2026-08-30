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
  uploaded: "bg-amber-50 text-amber-800 border-amber-200",
  dry_run_complete: "bg-sky-50 text-sky-800 border-sky-200",
  complete: "bg-emerald-50 text-emerald-800 border-emerald-200",
  failed: "bg-rose-50 text-rose-800 border-rose-200",
  rolled_back: "bg-stone-100 text-stone-600 border-stone-300",
};

export function StatusPill({ status }: { status: string }) {
  return (
    <span className={`shrink-0 rounded border px-2 py-0.5 text-xs ${
      TONE[status] ?? "bg-stone-100 text-stone-600 border-stone-300"}`}>
      {STATUS_LABEL[status] ?? status}
    </span>
  );
}
