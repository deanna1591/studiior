"use client";

import { useState } from "react";

/** The members an audience reaches this week, revealed on tap. */
export default function PreviewList({ members, count }: {
  members: { id: string; first_name: string; last_name: string }[]; count: number;
}) {
  const [open, setOpen] = useState(false);
  if (members.length === 0) return null;
  return (
    <div className="mt-2">
      <button type="button" onClick={() => setOpen((o) => !o)}
        className="text-[12px] text-ink underline decoration-line-2 underline-offset-4 hover:decoration-ink">
        {open ? "Hide who's in it" : "Show who's in it"}
      </button>
      {open && (
        <ul className="mt-2 flex flex-wrap gap-1.5">
          {members.map((m) => (
            <li key={m.id} className="rounded-full bg-paper px-2.5 py-0.5 text-[12px] text-ink-2">
              <a href={`/members/${m.id}`} className="hover:text-ink">
                {m.first_name} {m.last_name}
              </a>
            </li>
          ))}
          {count > members.length && (
            <li className="px-2 py-0.5 text-[12px] text-ink-3">+{count - members.length} more</li>
          )}
        </ul>
      )}
    </div>
  );
}
