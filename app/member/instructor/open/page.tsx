import { redirect } from "next/navigation";

// Decision 85 — the Studio Guide's "Can't make a class" section points at
// /instructor/open; the Open classes screen is /instructor/shifts.
export default function OpenIndex() {
  redirect("/instructor/shifts");
}
