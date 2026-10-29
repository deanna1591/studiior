import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { SECTIONS } from "@/lib/instructor-guide";
import { GuideRefs, GuideScreen, ImportantBox } from "@/components/instructor/guide-ui";
import { Icon } from "@/components/member/icons";

export const dynamic = "force-dynamic";

/**
 * THE STUDIO GUIDE (Decision 85, amendment (a)) — the app teaching itself, so a
 * studio does not write a guidebook. Short collapsible sections; each step shows
 * the real control to tap (drawn from the app's own components, so it always
 * matches the instructor's screen and the studio's theme), and some steps are a
 * simplified picture of a whole screen. No raw bracket notation ever reaches the
 * screen — every ref is a structured chip. Platform-wide text from
 * lib/instructor-guide; nothing studio-specific here.
 */
export default async function GuidePage() {
  const { ctx } = await instructorScreen();
  return (
    <InstructorShell ctx={ctx} title="Studio Guide">
      <p className="m-sub mb-4 text-ink-3">
        How the app works, in a minute. Tap a section to open it.
      </p>
      <div className="space-y-2.5">
        {SECTIONS.map((s) => {
          let n = 0; // numbers text steps only; a screen picture breaks the flow.
          return (
            <details key={s.title} className="m-card px-4 py-3.5">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-2">
                <span className="text-[15px] font-semibold leading-5 text-ink">{s.title}</span>
                <Icon name="chevron-down" size={16} className="shrink-0 text-ink-3" />
              </summary>

              {s.important && <div className="mt-3"><ImportantBox text={s.important} /></div>}
              {s.intro && <p className="mt-3 text-[13.5px] leading-[20px] text-ink-2">{s.intro}</p>}

              <div className="mt-3 space-y-3">
                {s.steps.map((step, i) => {
                  if (step.screen) {
                    return <GuideScreen key={i} name={step.screen} caption={step.caption} />;
                  }
                  n += 1;
                  return (
                    <div key={i} className="flex gap-2.5">
                      <span className="num mt-[1px] flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold"
                            style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>{n}</span>
                      <span className="min-w-0 flex-1">
                        <span className="block text-[13.5px] leading-[20px] text-ink-2">{step.text}</span>
                        <GuideRefs refs={step.refs} />
                      </span>
                    </div>
                  );
                })}
              </div>

              <Link href={s.go}
                className="m-sub mt-3 inline-flex items-center gap-1 underline underline-offset-4"
                style={{ color: "var(--accent-text)" }}>
                Go there
                <Icon name="chevron-right" size={14} />
              </Link>
            </details>
          );
        })}
      </div>
    </InstructorShell>
  );
}
