import { Icon } from "@/components/member/icons";
import { TABS, BUTTONS } from "@/lib/guide-ui-registry";
import { splitGuideText } from "@/lib/instructor-guide";
import type { GuideRef as Ref } from "@/lib/instructor-guide";

/**
 * Decision 85 amendment (a) — the guide draws the real thing to tap.
 *
 * ONE registry (lib/guide-ui-registry) maps every ui key to how the app draws
 * it, and these presentational pieces turn an entry into a chip or a picture:
 *  - a TAB renders the tab bar's own icon and label;
 *  - a BUTTON renders in the real app idiom (the accent primary pill, the ink
 *    on the accent chip, or the neutral secondary chip), non-interactive;
 *  - a SCREEN is a simplified, read-only rendering of a whole screen, built
 *    from the real components' classes with made-up names.
 * Everything is a <span>/<div>, never a <button> — nothing here is live, and
 * every colour is a theme token, so a chip always matches the studio's theme.
 *
 * No "use client": these are pure, so the server guide page and the client
 * intro-cards / hint both render them.
 */

const BUTTON_CLASS = "inline-flex items-center rounded-full px-3 py-1 text-[12px] leading-4 font-bold";
// Inline chips sit on the text baseline with a 4px gap each side, and wrap with
// the sentence (they are inline elements, so a long line breaks around them).
const INLINE = " align-baseline mx-1";

/** One ui ref as a chip. Inline (the default) renders it on the text baseline;
 *  a screen ref is block-level (GuideScreen), never here. */
export function GuideRef({ refr, inline = true }: { refr: Ref; inline?: boolean }) {
  const gap = inline ? INLINE : "";
  if (refr.kind === "tab") {
    const t = TABS[refr.key];
    return (
      <span className={`inline-flex items-center gap-1 rounded-lg border border-line-2 bg-surface px-2 py-0.5 text-[12px] leading-4 font-medium text-ink${gap}`}>
        {t && <Icon name={t.icon} size={13} className="text-ink-2" />}
        {refr.key}
      </span>
    );
  }
  if (refr.kind === "button") {
    const variant = BUTTONS[refr.key] ?? "outline";
    if (variant === "solid") {
      return <span className={BUTTON_CLASS + gap} style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>{refr.key}</span>;
    }
    if (variant === "tint") {
      return <span className={BUTTON_CLASS + gap} style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>{refr.key}</span>;
    }
    return <span className={`inline-flex items-center rounded-full border border-line-2 bg-surface px-3 py-1 text-[12px] leading-4 font-medium text-ink${gap}`}>{refr.key}</span>;
  }
  return null;
}

/** A guide line with its chips inline, exactly where each control is named —
 *  "Open [tab My schedule], tap the class, tap [button Can't make it]." renders
 *  the text runs and the chips in order, on one flowing line that wraps. The ONE
 *  parser (splitGuideText) decides the runs, so the node test asserts on the
 *  same split: no text run carries a bracket, every ref run resolves to a chip. */
export function GuideText({ text }: { text: string }) {
  return (
    <>
      {splitGuideText(text).map((run, i) =>
        run.t === "text"
          ? <span key={i}>{run.value}</span>
          : <GuideRef key={i} refr={{ kind: run.kind, key: run.key }} />,
      )}
    </>
  );
}

/**
 * The Important box — a rule that costs money or trust if missed. Bordered and
 * tinted with the studio accent at low opacity; ink on the accent chip is the
 * safe pairing on every preset and accent (the same pair GuideHint uses).
 */
export function ImportantBox({ text }: { text: string }) {
  return (
    <div className="mb-3 rounded-xl px-3 py-2.5"
         style={{ background: "var(--accent-chip)", border: "1px solid var(--accent-solid)" }}>
      <p className="text-[11px] font-bold uppercase tracking-wide text-ink-2">Important</p>
      <p className="mt-0.5 text-[13.5px] leading-[20px] text-ink">{text}</p>
    </div>
  );
}

// ---- Screen pictures -------------------------------------------------------
// Made-up names, no real members, no prices. Read-only renderings in the real
// classes so they look like the screen the instructor will actually open.

function Chip({ children, tone }: { children: React.ReactNode; tone: "solid" | "amber" | "accent" }) {
  const style = tone === "solid" ? { background: "var(--accent-solid)", color: "var(--accent-on-solid)" }
    : tone === "amber" ? { background: "var(--amber-tint)", color: "var(--ink)" }
    : { background: "var(--accent-chip)", color: "var(--ink)" };
  return <span className="rounded-full px-2.5 py-1 text-[12px] leading-4 font-medium" style={style}>{children}</span>;
}

function OutlineChip({ children }: { children: React.ReactNode }) {
  return <span className="rounded-full border border-line-2 bg-surface px-2.5 py-1 text-[12px] leading-4 font-medium text-ink">{children}</span>;
}

function RosterRow({ name, sub, children }: { name: string; sub: string; children?: React.ReactNode }) {
  return (
    <div className="rounded-xl bg-surface px-3 py-2.5" style={{ boxShadow: "0 1px 2px rgba(0,0,0,0.05)" }}>
      <div className="flex items-center gap-2.5">
        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-[13px] font-semibold"
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>{name.charAt(0)}</span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[14px] leading-5 text-ink">{name}</span>
          <span className="m-sub block text-ink-3">{sub}</span>
        </span>
      </div>
      {children}
    </div>
  );
}

function ScreenRoster() {
  return (
    <div className="space-y-2 rounded-2xl border border-line-2 bg-paper p-3">
      <div className="flex items-center justify-between gap-2">
        <span className="m-sub text-ink-2">Mon 10:00 · 3/8 booked</span>
        <span className="rounded-full px-3 py-1 text-[11px] leading-4 font-bold"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Checked in for pay</span>
      </div>
      <RosterRow name="Ana Reyes" sub="Here" />
      <RosterRow name="Bea Cruz" sub="Booked">
        <div className="mt-2"><Chip tone="solid">First ever class</Chip></div>
      </RosterRow>
      <RosterRow name="Cyrus Tan" sub="Booked">
        <p className="mt-2 rounded-lg px-2.5 py-2 text-[12.5px] leading-[18px] text-ink"
           style={{ background: "var(--coral-tint)", borderLeft: "3px solid var(--coral)" }}>
          Waiver not signed
        </p>
      </RosterRow>
      <RosterRow name="Dina Flores" sub="Booked">
        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          <Chip tone="amber">Unpaid</Chip>
          <OutlineChip>Paid at desk</OutlineChip>
          <OutlineChip>Sold a plan at desk</OutlineChip>
        </div>
      </RosterRow>
      <div className="rounded-xl bg-surface px-3 py-2.5" style={{ boxShadow: "0 1px 2px rgba(0,0,0,0.05)" }}>
        <p className="text-[14px] font-semibold text-ink">Add a walk-in</p>
        <p className="m-sub text-ink-3">Books them into this class and checks them in.</p>
      </div>
    </div>
  );
}

function FakeField({ placeholder }: { placeholder: string }) {
  return (
    <div className="w-full rounded-xl border border-line-2 bg-surface px-3 py-2 text-[14px] text-ink-3">{placeholder}</div>
  );
}

function ScreenAddWalkIn() {
  return (
    <div className="rounded-2xl border border-line-2 bg-paper p-3">
      <div className="rounded-xl bg-surface px-3.5 py-3.5" style={{ boxShadow: "0 1px 2px rgba(0,0,0,0.05)" }}>
        <p className="text-[14px] font-semibold text-ink">Add a walk-in</p>
        <div className="mt-3 space-y-2">
          <FakeField placeholder="Name" />
          <FakeField placeholder="Email" />
          <FakeField placeholder="Mobile (optional)" />
        </div>
        <span className="mt-3 block w-full rounded-xl py-2.5 text-center text-[14px] font-semibold"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Add</span>
        <p className="mt-2 text-[12.5px] leading-5 text-ink-2">Added — free first class</p>
      </div>
    </div>
  );
}

function ScreenPaidAtDesk() {
  return (
    <div className="rounded-2xl border border-line-2 bg-paper p-3">
      <RosterRow name="Dina Flores" sub="Booked">
        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          <Chip tone="amber">Unpaid</Chip>
          <OutlineChip>Paid at desk</OutlineChip>
        </div>
        <div className="mt-2 rounded-lg px-2.5 py-2.5" style={{ background: "var(--paper)" }}>
          <div className="flex gap-1.5">
            <span className="flex-1 rounded-xl px-2 py-1.5 text-center text-[12px] font-medium text-ink" style={{ background: "var(--accent-chip)" }}>GCash</span>
            <span className="flex-1 rounded-xl border border-line-2 bg-surface px-2 py-1.5 text-center text-[12px] font-medium text-ink">Cash</span>
            <span className="flex-1 rounded-xl border border-line-2 bg-surface px-2 py-1.5 text-center text-[12px] font-medium text-ink">Card</span>
          </div>
          <div className="mt-2"><FakeField placeholder="Amount" /></div>
          <div className="mt-2"><FakeField placeholder="Reference (optional)" /></div>
          <span className="mt-2 block w-full rounded-xl py-2 text-center text-[13px] font-semibold"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>Record payment</span>
        </div>
      </RosterRow>
    </div>
  );
}

const PICTURES: Record<string, () => React.ReactNode> = {
  "Roster": ScreenRoster,
  "Add a walk-in": ScreenAddWalkIn,
  "Paid at desk": ScreenPaidAtDesk,
};

/** A screen picture with its caption under it. Full width. */
export function GuideScreen({ name, caption }: { name: string; caption?: string }) {
  const Picture = PICTURES[name];
  if (!Picture) return null;
  return (
    <figure className="my-1">
      <Picture />
      {caption && <figcaption className="m-sub mt-1.5 text-ink-3">{caption}</figcaption>}
    </figure>
  );
}
