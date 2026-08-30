"use client";

import Link from "next/link";
import { useFormState } from "react-dom";
import { dismissSetupItem, type ActionState } from "./onboarding-actions";

export type SetupState = Record<string, { done: boolean; dismissed: boolean }>;

/** Order is the order a studio actually needs them in. */
const ITEMS: { key: string; label: string; hint: string; href?: string }[] = [
  { key: "rooms",          label: "Add your rooms",        hint: "Where classes happen, and how many people fit.", href: "/rooms" },
  { key: "class_types",    label: "Add your class types",  hint: "Reformer, mat, barre — with default length and capacity.", href: "/class-types" },
  { key: "instructors",    label: "Add your instructors",  hint: "Who teaches. They do not need logins yet.", href: "/instructors" },
  { key: "plans",          label: "Set up what you sell",  hint: "Memberships, packs and drop-ins.", href: "/plans" },
  { key: "schedule",       label: "Put your week on",      hint: "Your first classes, so members have something to book.", href: "/classes/new" },
  { key: "staff",          label: "Invite your team",      hint: "Front desk and managers, so you are not the only login." },
  { key: "connect_stripe", label: "Connect Stripe",        hint: "Take payments through your own Stripe account.", href: "/stripe" },
];

function Row({ item, state }: { item: (typeof ITEMS)[number]; state: { done: boolean; dismissed: boolean } }) {
  const [, action] = useFormState<ActionState, FormData>(dismissSetupItem, null);
  return (
    <li className="flex items-start justify-between gap-4 px-3 py-2.5">
      <div className="min-w-0">
        <div className="flex items-center gap-2 text-sm">
          <span className={state.done ? "text-emerald-700" : "text-stone-300"}>
            {state.done ? "✓" : "○"}
          </span>
          {item.href ? (
            <Link
              href={item.href}
              className={
                state.done
                  ? "text-stone-500 underline underline-offset-4"
                  : "font-medium underline underline-offset-4"
              }
            >
              {item.label}
            </Link>
          ) : (
            <span className={state.done ? "text-stone-500" : "font-medium"}>{item.label}</span>
          )}
        </div>
        {!state.done && <p className="mt-0.5 pl-6 text-xs text-stone-500">{item.hint}</p>}
      </div>
      {!state.done && (
        <form action={action} className="shrink-0">
          <input type="hidden" name="key" value={item.key} />
          <input type="hidden" name="undo" value={state.dismissed ? "1" : "0"} />
          <button className="text-xs text-stone-400 underline underline-offset-4 hover:text-stone-700">
            {state.dismissed ? "restore" : "dismiss"}
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

  if (live.length === 0) return null;
  if (done === live.length) {
    return (
      <section className="mb-6 rounded border border-emerald-300 bg-emerald-50 px-3 py-2.5 text-sm text-emerald-900">
        Setup complete — everything on the checklist is done.
      </section>
    );
  }

  return (
    <section className="mb-6 rounded border border-stone-200 bg-white">
      <header className="flex items-baseline justify-between gap-4 border-b border-stone-200 px-3 py-2.5">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-stone-500">
          Finish setting up
        </h2>
        <span className="text-xs text-stone-500">
          {done} of {live.length} done{hidden > 0 && ` · ${hidden} dismissed`}
        </span>
      </header>
      <ul className="divide-y divide-stone-100">
        {live.map((i) => (
          <Row key={i.key} item={i} state={state[i.key] ?? { done: false, dismissed: false }} />
        ))}
      </ul>
      <p className="border-t border-stone-100 px-3 py-2 text-xs text-stone-500">
        Do these in any order. Ticks come from your actual data, so they stay
        honest — remove every room and that item comes back.
      </p>
    </section>
  );
}
