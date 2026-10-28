import { redirect } from "next/navigation";

// Decision 85 — the Studio Guide's "Checking in" / "Walk-ins" / "Payments at
// the desk" sections point at /instructor/roster, but a roster is per-class:
// you pick one on My schedule and tap through to it. Send the go-there link
// there rather than invent a bare roster index.
export default function RosterIndex() {
  redirect("/instructor/schedule");
}
