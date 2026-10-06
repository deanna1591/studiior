// Decision 70 — caller role → invitable roles.
//   node --test test/team-roles.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { invitableRoles, canManageTeam } from "../lib/team-roles.mjs";

test("owner invites a manager or front desk", () => {
  assert.deepEqual(invitableRoles("owner"), ["manager", "front_desk"]);
});
test("manager invites front desk only", () => {
  assert.deepEqual(invitableRoles("manager"), ["front_desk"]);
});
test("front desk and instructor invite nobody", () => {
  assert.deepEqual(invitableRoles("front_desk"), []);
  assert.deepEqual(invitableRoles("instructor"), []);
  assert.deepEqual(invitableRoles("nonsense"), []);
});
test("only owner and manager manage the team", () => {
  assert.equal(canManageTeam("owner"), true);
  assert.equal(canManageTeam("manager"), true);
  assert.equal(canManageTeam("front_desk"), false);
  assert.equal(canManageTeam("instructor"), false);
});
