import Link from "next/link";
import type { TasksBlock } from "@/lib/dashboard";
import { Block } from "./block";

const TONE: Record<string, { dot: string; label: string }> = {
  urgent:   { dot: "var(--coral)",      label: "Now" },
  soon:     { dot: "var(--amber-deep)", label: "This week" },
  whenever: { dot: "var(--ink-3)",      label: "When you can" },
};

/**
 * 4.11. An action centre, derived — never a table.
 *
 * Every row here is a state that already exists somewhere in the schema, so it
 * appears when the thing is true and disappears when it is dealt with. There
 * is nothing to tick, nothing to go stale, and nothing that can disagree with
 * the screen it links to.
 *
 * Building a `tasks` table would have been this project's most repeated bug in
 * a new place: a schema with a writer nobody calls, next to
 * instructor_availability, class_series, class_types.color,
 * cancellation_reason and the twenty-six settings in SETTINGS_WITHOUT_UI.md.
 */
export default function Tasks({ t, error }: { t: TasksBlock | null; error?: string | null }) {
  return (
    <Block title="To do" error={error}>
      {!t ? null : t.state === "clear" ? (
        // SAYING NOTHING IS A FEATURE. A list that manufactures items every
        // morning to look busy trains the owner to stop reading it.
        <div className="rounded-lg border border-line bg-paper px-4 py-5">
          <p className="text-[14px] leading-[21px] text-ink">Nothing needs you today.</p>
          <p className="mt-1 max-w-[46ch] text-[12px] leading-[17px] text-ink-3">{t.clear_hint}</p>
        </div>
      ) : (
        <>
          <ul className="divide-y divide-line">
            {t.tasks.map((task) => {
              const tone = TONE[task.urgency] ?? TONE.whenever;
              return (
                <li key={task.key} className="flex gap-3 py-2.5">
                  <span
                    className="chip-dot mt-[7px] shrink-0"
                    style={{ background: tone.dot }}
                    aria-label={tone.label}
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-[13px] font-medium leading-[19px] text-ink">{task.title}</p>
                    <p className="mt-0.5 text-[12px] leading-[17px] text-ink-3">{task.detail}</p>
                    <Link
                      href={task.href}
                      className="mt-1 inline-block text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
                    >
                      {task.action}
                    </Link>
                  </div>
                </li>
              );
            })}
          </ul>
          <p className="mt-2 text-[11px] leading-4 text-ink-3">{t.not_built}</p>
        </>
      )}
    </Block>
  );
}
