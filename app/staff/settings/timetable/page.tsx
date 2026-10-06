import { redirect } from "next/navigation";

// Decision 71 — this settings group was merged; its content moved. Redirect to
// the new page and section.
export default function Redirect() {
  redirect("/settings/booking#horizon");
}
