"use client";

import Link from "next/link";
import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { createClassOccurrence, type CreateClassState } from "../../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";
import TierField from "@/components/tier-field";

type ClassType = { id: string; name: string; default_capacity: number; duration_minutes: number };

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Creating…" : "Create class"}</button>;
}

export default function CreateClassForm({
  classTypes, instructors, rooms, coreEnabled, flexEnabled,
}: {
  classTypes: ClassType[];
  instructors: { id: string; display_name: string }[];
  rooms: { id: string; name: string; capacity: number }[];
  coreEnabled: boolean;
  flexEnabled: boolean;
}) {
  const [state, action] = useFormState<CreateClassState, FormData>(createClassOccurrence, null);
  const [capacity, setCapacity] = useState(classTypes[0]?.default_capacity ?? 8);

  // A clean create redirects to the dashboard; a success we still see here
  // carries a warning worth reading (a standalone flex, or outside hours).
  if (state && state.ok) {
    return (
      <div className="max-w-md space-y-4">
        <Notice kind="ok">{state.message}</Notice>
        <div className="flex gap-3">
          <Link href="/" className={buttonClass}>Back to the dashboard</Link>
          <Link href="/schedule" className="text-[13px] text-ink-2 underline underline-offset-4 self-center">
            See it on the schedule
          </Link>
        </div>
      </div>
    );
  }

  return (
    <form action={action} className="max-w-md space-y-4">
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}

      <Field label="Class type">
        <select
          name="class_type_id"
          required
          className={inputClass}
          onChange={(e) => {
            const ct = classTypes.find((c) => c.id === e.target.value);
            if (ct) setCapacity(ct.default_capacity);
          }}
        >
          {classTypes.map((c) => (
            <option key={c.id} value={c.id}>{c.name} ({c.duration_minutes} min)</option>
          ))}
        </select>
      </Field>

      <Field label="Instructor">
        <select name="instructor_id" className={inputClass} defaultValue="">
          <option value="">Unassigned</option>
          {instructors.map((i) => <option key={i.id} value={i.id}>{i.display_name}</option>)}
        </select>
      </Field>

      <Field label="Room">
        <select name="room_id" className={inputClass} defaultValue="">
          <option value="">No room</option>
          {rooms.map((r) => <option key={r.id} value={r.id}>{r.name} (holds {r.capacity})</option>)}
        </select>
      </Field>

      <div className="grid grid-cols-2 gap-3">
        <Field label="Date"><input name="date" type="date" required className={inputClass} /></Field>
        <Field label="Start time"><input name="time" type="time" required defaultValue="07:00" className={inputClass} /></Field>
      </div>

      <Field label="Capacity">
        <input
          name="capacity" type="number" min={1} required className={inputClass}
          value={capacity} onChange={(e) => setCapacity(Number(e.target.value))}
        />
      </Field>

      {/* Only shown when the studio has guarantees or flex on; absent otherwise,
          and the class is created core exactly as before. */}
      <TierField coreEnabled={coreEnabled} flexEnabled={flexEnabled} />

      <p className="text-xs text-ink-3">
        The date and time are studio-local. They are converted to UTC at the instant
        they refer to, so the class keeps its wall-clock time across a DST change.
      </p>

      <Submit />
    </form>
  );
}
