// Decision 70 — which roles a caller may invite. Owner invites a manager or
// front desk; a manager invites front desk only; nobody else invites. Pure, so
// the invite form's role select and the RPC guard agree. (The RPC is still the
// boundary; this only decides what the select offers.)

/**
 * @param {string} callerRole
 * @returns {("manager"|"front_desk")[]}
 */
export function invitableRoles(callerRole) {
  if (callerRole === "owner") return ["manager", "front_desk"];
  if (callerRole === "manager") return ["front_desk"];
  return [];
}

/** Whether a caller may change roles / remove managers / promote to owner. */
export function canManageTeam(callerRole) {
  return callerRole === "owner" || callerRole === "manager";
}
