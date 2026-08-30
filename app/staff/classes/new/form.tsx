"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { createClassOccurrence } from "../../actions";
import { Field, Notice, buttonClass, inputClass } from "@/components/ui";

type ClassType = { id: string; name: string; default_capacity: number; duration_minutes: number };

function Submit() {
  const { pending } = useFormStatus();
  return <button className={buttonClass} disabled={pending}>{pending ? "Creating…" : "Create class"}</button>;
}

export default function CreateClassForm({
  classTypes, instructors, rooms,
}: {
  classTypes: ClassType[];
  instructors: { id: string; display_name: string }[];
  rooms: { id: string; name: string; capacity: number }[];
}) {
  const [error, action] = useFormState(createClassOccurrence, null);
  const [capacity, setCapacity] = useState(classTypes[0]?.default_capacity ?? 8);

  return (
    <form action={action} className="max-w-md space-y-4">
      {error && <Notice kind="error">{error}</Notice>}

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

      <p className="text-xs text-ink-3">
        The date and time are studio-local. They are converted to UTC at the instant
        they refer to, so the class keeps its wall-clock time across a DST change.
      </p>

      <Submit />
    </form>
  );
}
