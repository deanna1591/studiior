"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { beginConnect, type ConnectState } from "./actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button className={buttonClass} disabled={pending}>
      {pending ? "Opening Stripe…" : "Connect Stripe"}
    </button>
  );
}

export default function ConnectButton() {
  const [state, action] = useFormState<ConnectState, FormData>(beginConnect, null);
  return (
    <form action={action} className="space-y-3">
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
      <Submit />
    </form>
  );
}
