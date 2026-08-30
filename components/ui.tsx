import Link from "next/link";
import Rail, { type RailItem, type RailUser } from "./rail";
import Banner, { type BannerMsg } from "./banner";

/* --------------------------------------------------------------------------
   Shell — rail, one banner slot, page head, content.
   -------------------------------------------------------------------------- */

export function AppShell({
  studioName, location, items, user, signOut,
  title, actions, banner, filters, children,
}: {
  studioName: string;
  location: string | null;
  items: RailItem[];
  user: RailUser;
  signOut: React.ReactNode;
  title: string;
  actions?: React.ReactNode;
  banner?: BannerMsg | null;
  filters?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <>
      <Rail studioName={studioName} location={location} items={items} user={user} signOut={signOut} />
      <div className="md:pl-[--rail-w]">
        {/* Left-aligned rather than centred: the content keeps one left edge
            with the rail, so the eye has a single column to track down. */}
        <main className="max-w-[1120px] px-5 py-6 md:px-8 md:py-8">
          <Banner msg={banner ?? null} />
          <div className="mb-5 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
            <h1 className="display text-ink">{title}</h1>
            {actions && <div className="flex flex-wrap items-center gap-4">{actions}</div>}
          </div>
          {filters && <div className="mb-4">{filters}</div>}
          {children}
        </main>
      </div>
    </>
  );
}

/** Page head for screens that sit inside the shell without their own rail. */
export function Shell({
  title, subtitle, right, children,
}: {
  title: string; subtitle?: string; right?: React.ReactNode; children: React.ReactNode;
}) {
  return (
    <div className="mx-auto max-w-[1120px] px-5 py-8">
      <header className="mb-6 flex flex-wrap items-baseline justify-between gap-4 border-b border-line pb-4">
        <div>
          <h1 className="display text-ink">{title}</h1>
          {subtitle && <p className="mt-1 text-[13px] leading-[18px] text-ink-3">{subtitle}</p>}
        </div>
        {right && <div className="flex items-center gap-4">{right}</div>}
      </header>
      {children}
    </div>
  );
}

/* --------------------------------------------------------------------------
   Controls
   -------------------------------------------------------------------------- */

export function Field({ label, hint, children }: {
  label: string; hint?: string; children: React.ReactNode;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-[13px] font-medium leading-[18px] text-ink">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-[11px] leading-[15px] text-ink-3">{hint}</span>}
    </label>
  );
}

export const inputClass =
  "w-full rounded border border-line-2 bg-surface px-2.5 py-2 text-[13px] leading-[18px] " +
  "text-ink placeholder:text-ink-3 focus:border-lime-text focus:outline-none";

export const buttonClass =
  "inline-flex items-center rounded bg-ink px-3.5 py-2 text-[13px] font-medium leading-[18px] " +
  "text-paper hover:bg-ink-2 disabled:opacity-45";

export const buttonQuietClass =
  "inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 " +
  "text-[13px] leading-[18px] text-ink hover:bg-paper disabled:opacity-45";

export function Notice({ kind, children }: { kind: "error" | "ok"; children: React.ReactNode }) {
  // Error text is ink on a coral wash with a coral rule. Coral itself is 4.47
  // against white and cannot set a sentence, and an error is the last place to
  // spend a near-miss.
  const err = kind === "error";
  return (
    <div
      className={`mb-4 border-l-[3px] px-3 py-2 text-[13px] leading-[18px] text-ink ${
        err ? "bg-coral-tint" : "bg-lime-tint"
      }`}
      style={{ borderLeftColor: err ? "var(--coral)" : "var(--lime-text)" }}
    >
      {children}
    </div>
  );
}

export function NavLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <Link href={href} className="text-[13px] leading-[18px] text-lime-text underline underline-offset-4 hover:text-lime-text2">
      {children}
    </Link>
  );
}

/** Pill filters. Active is a lime fill with dark-lime text — 6.18. */
export function Pill({ href, active, children }: {
  href: string; active?: boolean; children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className={`inline-flex h-7 items-center rounded-full border px-3 text-[12px] leading-none ${
        active
          ? "border-lime-text bg-lime-tint font-medium text-lime-text"
          : "border-line-2 bg-surface text-ink-2 hover:border-ink-3 hover:text-ink"
      }`}
    >
      {children}
    </Link>
  );
}

export function PillRow({ children, right }: { children: React.ReactNode; right?: React.ReactNode }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div className="flex flex-wrap items-center gap-1.5">{children}</div>
      {right}
    </div>
  );
}

/** Segmented control — the day/week toggle. */
export function Segmented({ options }: {
  options: { href: string; label: string; active: boolean }[];
}) {
  return (
    <div className="inline-flex h-7 overflow-hidden rounded-full border border-line-2 bg-surface">
      {options.map((o, i) => (
        <Link
          key={o.href}
          href={o.href}
          className={`inline-flex items-center px-3 text-[12px] leading-none ${
            i > 0 ? "border-l border-line-2" : ""
          } ${o.active ? "bg-lime-tint font-medium text-lime-text" : "text-ink-2 hover:text-ink"}`}
        >
          {o.label}
        </Link>
      ))}
    </div>
  );
}

/** Empty states say what to do next. */
export function Empty({ children }: { children: React.ReactNode }) {
  return (
    <div className="border border-dashed border-line-2 px-4 py-8 text-center text-[13px] leading-[18px] text-ink-2">
      {children}
    </div>
  );
}

/** What a screen says to someone whose role cannot use it. */
export function Denied({ what, role }: { what: string; role: string }) {
  return (
    <Empty>
      {what} is for owners and managers, and you are signed in as{" "}
      {role.replace("_", " ")}. Ask an owner or a manager to make the change.
    </Empty>
  );
}

export function SectionLabel({ children }: { children: React.ReactNode }) {
  return <h2 className="section-label mb-2 text-ink-2">{children}</h2>;
}

/** A plain list surface: rows on white, hairlines between. No cards. */
export function Rows({ children }: { children: React.ReactNode }) {
  return <div className="divide-y divide-line border-y border-line bg-surface">{children}</div>;
}
