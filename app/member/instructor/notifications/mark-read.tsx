"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { markNotificationsRead } from "../actions";

/**
 * Marks the list read when it is actually viewed (an effect, not render — so a
 * prefetch never clears the bell), then refreshes so the count settles to zero.
 */
export function MarkNotificationsRead({ instructorId }: { instructorId: string }) {
  const router = useRouter();
  const done = useRef(false);
  useEffect(() => {
    if (done.current) return;
    done.current = true;
    markNotificationsRead(instructorId).then(() => router.refresh());
  }, [instructorId, router]);
  return null;
}
