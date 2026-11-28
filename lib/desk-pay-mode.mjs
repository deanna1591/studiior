// Decision 73 (c) and 103 (p): the three "Pay at the desk" modes on Settings →
// Booking, one list so the radio and its test agree.
export const DESK_PAY_MODES = [
  { value: "earned", label: "Earned",
    help: "Members can pay at the desk until they miss or late-cancel a desk booking." },
  { value: "first_visit_only", label: "First visit only",
    help: "Members can pay at the desk for their first booking only." },
  { value: "staff_only", label: "Staff only",
    help: "Staff only. Members pay online. Front desk and up can still mark a booking to pay at the studio." },
];

export function normaliseDeskPayMode(v) {
  return DESK_PAY_MODES.some((m) => m.value === v) ? v : "earned";
}
