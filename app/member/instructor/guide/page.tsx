import Link from "next/link";
import { instructorScreen } from "@/lib/instructor";
import InstructorShell from "@/components/instructor/shell";
import { SECTIONS } from "@/lib/instructor-guide";
import { Icon } from "@/components/member/icons";

export const dynamic = "force-dynamic";

/**
 * THE STUDIO GUIDE (Decision 85) — the app teaching itself, so a studio does not
 * write a guidebook. Short sections, each a collapsible block, each with a Go
 * there link to the real screen. Platform-wide text from lib/instructor-guide;
 * there is nothing studio-specific here.
 */
export default async function GuidePage() {
  const { ctx } = await instructorScreen();
  return (
    <InstructorShell ctx={ctx} title="Studio Guide">
      <p className="m-sub mb-4 text-ink-3">
        How the app works, in a minute. Tap a section to open it.
      </p>
      <div className="space-y-2.5">
        {SECTIONS.map((s) => (
          <details key={s.title} className="m-card px-4 py-3.5">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-2">
              <span className="text-[15px] font-semibold leading-5 text-ink">{s.title}</span>
              <Icon name="chevron-down" size={16} className="shrink-0 text-ink-3" />
            </summary>
            <ul className="mt-3 space-y-2">
              {s.lines.map((line, i) => (
                <li key={i} className="flex gap-2 text-[13.5px] leading-[20px] text-ink-2">
                  <span className="mt-[7px] h-1 w-1 shrink-0 rounded-full"
                        style={{ background: "var(--line-2)" }} aria-hidden />
                  <span>{line}</span>
                </li>
              ))}
            </ul>
            <Link href={s.go}
              className="m-sub mt-3 inline-flex items-center gap-1 underline underline-offset-4"
              style={{ color: "var(--accent-text)" }}>
              Go there
              <Icon name="chevron-right" size={14} />
            </Link>
          </details>
        ))}
      </div>
    </InstructorShell>
  );
}
