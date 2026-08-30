/**
 * Deliberately not a design system. Just enough shared markup to keep the slice
 * legible; styling beyond that is out of scope.
 */
import Link from "next/link";

export function Shell({
  title, subtitle, right, children,
}: {
  title: string; subtitle?: string; right?: React.ReactNode; children: React.ReactNode;
}) {
  return (
    <div className="mx-auto max-w-5xl px-5 py-8">
      <header className="mb-6 flex items-start justify-between gap-4 border-b border-stone-200 pb-4">
        <div>
          <h1 className="text-xl font-semibold tracking-tight">{title}</h1>
          {subtitle && <p className="mt-0.5 text-sm text-stone-500">{subtitle}</p>}
        </div>
        {right && <div className="flex items-center gap-3 text-sm">{right}</div>}
      </header>
      {children}
    </div>
  );
}

export function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-stone-700">{label}</span>
      {children}
    </label>
  );
}

export const inputClass =
  "w-full rounded border border-stone-300 bg-white px-3 py-2 text-sm " +
  "focus:border-stone-500 focus:outline-none";

export const buttonClass =
  "rounded bg-stone-900 px-4 py-2 text-sm font-medium text-white " +
  "hover:bg-stone-700 disabled:opacity-50";

export function Notice({ kind, children }: { kind: "error" | "ok"; children: React.ReactNode }) {
  const tone =
    kind === "error"
      ? "border-red-300 bg-red-50 text-red-800"
      : "border-emerald-300 bg-emerald-50 text-emerald-800";
  return <div className={`mb-4 rounded border px-3 py-2 text-sm ${tone}`}>{children}</div>;
}

export function NavLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <Link href={href} className="text-stone-600 underline underline-offset-4 hover:text-stone-900">
      {children}
    </Link>
  );
}
