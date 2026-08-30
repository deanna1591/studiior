"use client";

import Link from "next/link";
import { useFormState } from "react-dom";
import { dismissSetupItem, type ActionState } from "../onboarding-actions";

import type { SetupState } from "@/lib/setup";

/** Order is the order a studio actually needs them in. */
const ITEMS: { key: string; label: string; hint: string; href?: string }[] = [
  { key: "rooms",          label: "Add your rooms",       hint: "Where classes happen, and how many people fit.", href: "/rooms" },
  { key: "class_types",    label: "Add your class types", hint: "Reformer, mat, barre — with default length and capacity.", href: "/class-types" },
  { key: "instructors",    label: "Add your instructors", hint: "Who teaches. They do not need logins yet.", href: "/instructors" },
  { key: "plans",          label: "Set up what you sell", hint: "Memberships, packs and drop-ins.", href: "/plans" },
  { key: "schedule",       label: "Put your week on",     hint: "Your first classes, so members have something to book.", href: "/classes/new" },
  { key: "staff",          label: "Invite your team",     hint: "Front desk and managers, so you are not the only login." },
  { key: "connect_stripe", label: "Connect Stripe",       hint: "Take payments through your own Stripe account.", href: "/stripe" },
];

function Tick({ done }: { done: boolean }) {
  return done ? (
    <span className="mt-[3px] flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-lime" aria-hidden>
      <svg width="9" height="9" viewBox="0 0 9 9"><path d="M1 4.6l2.2 2.2L8 2" stroke="var(--ink)" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" /></svg>
    </span>
  ) : (
    <span className="mt-[3px] h-4 w-4 shrink-0 rounded-full border border-line-2" aria-hidden />
  );
}

function Row({ item, state }: { item: (typeof ITEMS)[number]; state: { done: boolean; dismissed: boolean } }) {
  const [, action] = useFormState<ActionState, FormData>(dismissSetupItem, null);
  return (
    <li className="flex items-start justify-between gap-4 px-3 py-2.5">
      <div className="flex min-w-0 gap-2.5">
        <Tick done={state.done} />
        <div className="min-w-0">
          {item.href && !state.done ? (
            <Link href={item.href} className="text-[13px] font-medium leading-[18px] text-lime-text underline underline-offset-4 hover:text-lime-text2">
              {item.label}
            </Link>
          ) : (
            <span className={`text-[13px] leading-[18px] ${state.done ? "text-ink-3" : "font-medium text-ink"}`}>
              {item.label}
            </span>
          )}
          {!state.done && <p className="mt-0.5 text-[12px] leading-4 text-ink-3">{item.hint}</p>}
        </div>
      </div>
      {!state.done && (
        <form action={action} className="shrink-0">
          <input type="hidden" name="key" value={item.key} />
          <input type="hidden" name="undo" value={state.dismissed ? "1" : "0"} />
          <button className="text-[12px] leading-4 text-ink-3 underline underline-offset-4 hover:text-ink">
            {state.dismissed ? "Restore" : "Skip"}
          </button>
        </form>
      )}
    </li>
  );
}

export default function SetupChecklist({ state }: { state: SetupState }) {
  const live = ITEMS.filter((i) => !state[i.key]?.dismissed);
  const done = live.filter((i) => state[i.key]?.done).length;
  const hidden = ITEMS.length - live.length;

  // Ticks come from live data, so finishing the last item makes the whole
  // thing disappear on the next load rather than lingering as a done list.
  if (live.length === 0 || done === live.length) return null;

  return (
    <section className="mb-6 border-y border-line bg-surface">
      <header className="flex items-baseline justify-between gap-4 border-b border-line px-3 py-2.5">
        <h2 className="section-label text-ink-2">Finish setting up</h2>
        <span className="num text-[12px] text-ink-3">
          {done}/{live.length}
          {hidden > 0 && <span className="font-sans"> · {hidden} skipped</span>}
        </span>
      </header>
      <ul className="divide-y divide-line">
        {live.map((i) => (
          <Row key={i.key} item={i} state={state[i.key] ?? { done: false, dismissed: false }} />
        ))}
      </ul>
    </section>
  );
}
