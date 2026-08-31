"use client";

import { useFormState, useFormStatus } from "react-dom";
import { signIn } from "../actions";

function Submit({ onImage }: { onImage: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
      className="m-action w-full rounded-xl text-[16px] font-semibold disabled:opacity-60"
    >
      {pending ? "Signing in…" : "Sign in"}
    </button>
  );
}

/**
 * The entrance form.
 *
 * Two tones, because the panel behind it is two different things: over a
 * studio photograph it is dark glass and everything on it is white; over the
 * accent gradient it is the app's own surface and everything on it is ink.
 * Contrast is knowable in both cases, which is the whole reason for the split
 * — a single translucent treatment would have text sitting on whatever the
 * photograph happened to be doing.
 */
export default function LoginForm({ onImage }: { onImage: boolean }) {
  const [error, action] = useFormState(signIn, null);

  const field = onImage
    ? "m-glass-field m-tap w-full rounded-xl px-3.5 text-[16px] outline-none"
    : "m-tap w-full rounded-xl border border-line-2 bg-surface px-3.5 text-[16px] text-ink outline-none";
  const label = onImage ? "text-white/80" : "text-ink-2";

  return (
    <form action={action} className="space-y-3">
      {error && (
        <p
          role="alert"
          className="m-sub rounded-xl px-3 py-2"
          style={
            onImage
              ? { background: "rgb(207 62 25 / 0.92)", color: "#FFFFFF" }
              : { background: "var(--coral-tint)", color: "var(--ink)" }
          }
        >
          {error}
        </p>
      )}

      <label className="block">
        <span className={`m-micro mb-1 block ${label}`}>Email</span>
        <input name="email" type="email" required autoComplete="email"
               inputMode="email" className={field} />
      </label>
      <label className="block">
        <span className={`m-micro mb-1 block ${label}`}>Password</span>
        <input name="password" type="password" required autoComplete="current-password"
               className={field} />
      </label>

      <Submit onImage={onImage} />
    </form>
  );
}
