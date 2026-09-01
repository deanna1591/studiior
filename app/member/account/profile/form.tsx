"use client";

import { useFormState, useFormStatus } from "react-dom";
import { updateProfile, uploadAvatar } from "../../actions";
import Avatar from "@/components/member/avatar";
import IconChip from "@/components/member/icon-chip";
import { Note } from "@/components/member/ui";

function Save({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
      className="m-action mt-5 w-full rounded-xl text-[16px] font-semibold disabled:opacity-60"
    >
      {pending ? "Saving…" : label}
    </button>
  );
}

function PhotoSubmit() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
            className="m-tap rounded-xl border border-line-2 bg-surface px-4 text-[14px] font-medium text-ink disabled:opacity-60">
      {pending ? "Uploading…" : "Choose a photo"}
    </button>
  );
}

const field =
  "m-tap w-full rounded-xl border border-line-2 bg-surface px-3.5 text-[16px] text-ink outline-none";

export default function ProfileForm({
  name, avatarUrl, preferredName, phone, emergencyName, emergencyPhone,
}: {
  name: string;
  avatarUrl: string | null;
  preferredName: string;
  phone: string;
  emergencyName: string;
  emergencyPhone: string;
}) {
  const [state, action] = useFormState(updateProfile, null);
  const [photoState, photoAction] = useFormState(uploadAvatar, null);

  return (
    <>
      <form action={photoAction} className="m-card mb-4 flex items-center gap-4 p-5">
        <Avatar name={name} url={avatarUrl} size={72} />
        <div className="min-w-0 flex-1">
          {photoState && <Note ok={photoState.ok}>{photoState.message}</Note>}
          <label className="block">
            <span className="sr-only">Choose a photo</span>
            <input name="avatar" type="file" accept="image/png,image/jpeg,image/webp"
                   className="block w-full text-[13px] file:mr-3 file:rounded-lg file:border-0 file:bg-ink file:px-3 file:py-2 file:text-[13px] file:text-surface" />
          </label>
          <p className="m-meta mt-1.5 text-ink-3">
            Your instructor sees this on the class list, so they know who you are.
          </p>
          <div className="mt-2"><PhotoSubmit /></div>
        </div>
      </form>

      <form action={action} className="m-card p-5">
        {state && <Note ok={state.ok}>{state.message}</Note>}

        <label className="block">
          <span className="m-meta mb-1.5 block text-ink-2">What we should call you</span>
          <input name="preferred_name" defaultValue={preferredName} className={field}
                 placeholder={name} />
          <span className="m-meta mt-1 block text-ink-3">
            Leave it blank and we&rsquo;ll use {name || "your first name"}.
          </span>
        </label>

        <label className="mt-4 block">
          <span className="m-meta mb-1.5 block text-ink-2">Phone</span>
          <input name="phone" type="tel" inputMode="tel" defaultValue={phone} className={field} />
        </label>

        <div className="mt-6 border-t border-line pt-5">
          <p className="flex items-center gap-2.5">
            <IconChip name="shield" />
            <span className="m-body font-medium text-ink">Emergency contact</span>
          </p>
          <p className="m-meta mt-1.5 text-ink-3">
            Who the studio should ring if something happens in class. Only the
            studio sees this.
          </p>
          <label className="mt-3 block">
            <span className="m-meta mb-1.5 block text-ink-2">Name</span>
            <input name="emergency_name" defaultValue={emergencyName} className={field} />
          </label>
          <label className="mt-3 block">
            <span className="m-meta mb-1.5 block text-ink-2">Their phone</span>
            <input name="emergency_phone" type="tel" inputMode="tel"
                   defaultValue={emergencyPhone} className={field} />
          </label>
        </div>

        <Save label="Save" />
      </form>
    </>
  );
}
