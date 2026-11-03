import { redirect } from "next/navigation";

// Decision 88 slice B — the payments screen moved to /payments (the wallet, with
// tabs and receipts). This old address redirects so any saved link still lands.
export default function OldPayments() {
  redirect("/payments");
}
