import { redirect } from "next/navigation";

// Decision 88(c): merged into "My purchases".
export default function OldPayments() {
  redirect("/purchases?tab=payments");
}
