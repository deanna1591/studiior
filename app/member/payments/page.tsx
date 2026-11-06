import { redirect } from "next/navigation";

// Decision 88(c): Payments and Purchases merged into one "My purchases" screen.
export default function PaymentsRedirect() {
  redirect("/purchases?tab=payments");
}
