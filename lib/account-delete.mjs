// Decision 69 — member self-service account deletion. The confirmation gate and
// the plain-language consequences, pure so the server action and a node test
// agree (and so the page and the form show the same list).

/** The member must type DELETE (case/space tolerant) to confirm. */
export function isDeleteConfirmed(typed) {
  return typeof typed === "string" && typed.trim().toUpperCase() === "DELETE";
}

/** What happens, in plain language, shown before the member confirms. */
export const DELETE_CONSEQUENCES = [
  "Any classes you have booked will be cancelled.",
  "Any remaining membership or credits are forfeited — there is no automatic refund.",
  "Your sign-in and personal details are removed.",
  "Your booking and payment history is kept for the studio's records, but is no longer linked to your name.",
  "This cannot be undone.",
];
