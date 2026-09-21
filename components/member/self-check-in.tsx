"use client";

import { useState, useTransition } from "react";
import { selfCheckIn } from "@/app/member/actions";

/**
 * Decision 35 — the Check in button in the Home hero. On press it asks the phone
 * for a location (`enableHighAccuracy`), sends whatever it gets, and lets
 * self_check_in() decide (window + geofence + waiver, all server-side). A denied
 * or unavailable location sends nulls, which the server turns into "you need to
 * be at the studio" when the studio requires one — the button never blocks
 * itself. The reason comes back as a sentence and shows as a bottom toast.
 */
export default function SelfCheckIn({ bookingId }: { bookingId: string }) {
  const [msg, setMsg] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [pending, start] = useTransition();

  function run(lat: number | null, lng: number | null, accuracy: number | null) {
    start(async () => {
      const r = await selfCheckIn(bookingId, lat, lng, accuracy);
      setMsg(r?.message ?? null);
      if (r?.ok) setDone(true);
    });
  }

  function go() {
    setMsg(null);
    if (typeof navigator === "undefined" || !navigator.geolocation) { run(null, null, null); return; }
    navigator.geolocation.getCurrentPosition(
      (p) => run(p.coords.latitude, p.coords.longitude, p.coords.accuracy),
      () => run(null, null, null),   // denied / unavailable: send nulls, server decides
      { enableHighAccuracy: true, timeout: 10_000, maximumAge: 0 },
    );
  }

  return (
    <>
      <button type="button" onClick={go} disabled={pending || done}
              className="m-tap flex shrink-0 items-center rounded-full px-4 text-[13px] font-bold disabled:opacity-90"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        {done ? "Checked in ✓" : pending ? "Checking in…" : "Check in"}
      </button>
      {msg && (
        <div className="fixed inset-x-0 bottom-[92px] z-50 flex justify-center px-4" role="status">
          <p className="m-card max-w-sm px-4 py-3 text-center text-[14px] leading-5 text-ink">{msg}</p>
        </div>
      )}
    </>
  );
}
