"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

/**
 * Counts the code down and fetches the next one.
 *
 * The rotation is the security property — a screenshot is worthless thirty
 * seconds later — so it has to be visible, or a member holds up a stale code
 * and blames the app when the desk says no.
 */
export default function Rotator({ seconds }: { seconds: number }) {
  const [left, setLeft] = useState(seconds);
  const router = useRouter();

  useEffect(() => setLeft(seconds), [seconds]);

  useEffect(() => {
    const t = setInterval(() => {
      setLeft((n) => {
        if (n <= 1) {
          router.refresh();
          return 30;
        }
        return n - 1;
      });
    }, 1000);
    return () => clearInterval(t);
  }, [router]);

  return (
    <div className="mt-6 w-full max-w-[340px]">
      <div className="h-1 w-full overflow-hidden rounded-full bg-line">
        <div
          className="h-full bg-lime transition-[width] duration-1000 ease-linear"
          style={{ width: `${Math.max(0, Math.min(100, (left / 30) * 100))}%` }}
        />
      </div>
      <p className="m-micro mt-2 text-center text-ink-3">
        A new code in <span className="num">{left}</span>s
      </p>
    </div>
  );
}
