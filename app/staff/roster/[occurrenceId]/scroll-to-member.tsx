"use client";

import { useEffect } from "react";

/**
 * Decision 83 — a member's Journey row links to a class roster with ?member=…;
 * on arrival, scroll that member's row into view and flash it so the jump lands
 * somewhere obvious. Pure client behaviour; nothing leaves. Mirrors the settings
 * search jump (components/staff/settings-section.tsx).
 */
export default function ScrollToMember({ memberId }: { memberId: string }) {
  useEffect(() => {
    if (typeof window === "undefined") return;
    const el = document.getElementById(`roster-member-${memberId}`);
    if (!el) return;
    el.scrollIntoView({ behavior: "smooth", block: "center" });
    el.classList.add("settings-flash");
    const t = setTimeout(() => el.classList.remove("settings-flash"), 1600);
    return () => clearTimeout(t);
  }, [memberId]);
  return null;
}
