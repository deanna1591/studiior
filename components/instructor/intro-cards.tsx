"use client";

import { useRef, useState, useTransition } from "react";
import { INTRO_CARDS, INTRO_DONE_LABEL, fillStudio } from "@/lib/instructor-guide";
import { GuideRefs } from "@/components/instructor/guide-ui";

/**
 * Decision 85 — the first-open intro: five cards, shown once per person on the
 * home screen while guide_seen_at is null. Next or swipe through them; Got it on
 * the last calls instructor_guide_mark('intro') and it does not return. "Show
 * the intro again" on Me resets the flag.
 */
export default function IntroCards({
  studioName, onDone,
}: { studioName: string; onDone: () => Promise<void> }) {
  const [i, setI] = useState(0);
  const [done, setDone] = useState(false);
  const [, start] = useTransition();
  const touchX = useRef<number | null>(null);
  if (done) return null;

  const card = INTRO_CARDS[i];
  const last = i === INTRO_CARDS.length - 1;
  const go = (n: number) => setI(Math.max(0, Math.min(INTRO_CARDS.length - 1, n)));
  const finish = () => { setDone(true); start(() => { onDone(); }); };

  return (
    <section
      className="m-card mb-4 px-5 py-5"
      aria-label="Welcome to the app"
      onTouchStart={(e) => { touchX.current = e.changedTouches[0].clientX; }}
      onTouchEnd={(e) => {
        if (touchX.current === null) return;
        const dx = e.changedTouches[0].clientX - touchX.current;
        touchX.current = null;
        if (dx < -40) go(i + 1);
        else if (dx > 40) go(i - 1);
      }}
    >
      <p className="m-sub text-ink-3">
        <span className="num">{i + 1}</span> of <span className="num">{INTRO_CARDS.length}</span>
      </p>
      <h2 className="mt-1 text-[20px] font-semibold leading-7 text-ink">
        {fillStudio(card.title, studioName)}
      </h2>
      <p className="mt-1.5 text-[14px] leading-[21px] text-ink-2">{card.body}</p>
      <GuideRefs refs={card.refs} />
      <div className="mt-4 flex items-center gap-2">
        <div className="flex flex-1 items-center gap-1.5" aria-hidden>
          {INTRO_CARDS.map((_, k) => (
            <span key={k} className="h-1.5 w-1.5 rounded-full"
              style={{ background: k === i ? "var(--lime-text)" : "var(--line-2)" }} />
          ))}
        </div>
        {i > 0 && (
          <button type="button" onClick={() => go(i - 1)}
            className="m-tap rounded-full px-4 text-[13px] font-semibold"
            style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
            Back
          </button>
        )}
        <button type="button" onClick={() => (last ? finish() : go(i + 1))}
          className="m-tap rounded-full px-5 text-[13px] font-bold"
          style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
          {last ? INTRO_DONE_LABEL : "Next"}
        </button>
      </div>
    </section>
  );
}
