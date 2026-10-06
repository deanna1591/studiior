"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass, inputClass } from "@/components/ui";
import { invitableRoles } from "@/lib/team-roles";
import { inviteStaff, rowDispatch, type TeamState } from "./actions";

export type TeamRow = {
  staff_id: string;
  email: string;
  name: string | null;
  role: string;
  status: string;
  last_sign_in_at: string | null;
  is_self: boolean;
};

const ROLE_LABEL: Record<string, string> = {
  owner: "Owner", manager: "Manager", front_desk: "Front desk", instructor: "Instructor",
};

function Btn({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "…" : children}</button>;
}

export default function TeamClient({ rows, callerRole }: { rows: TeamRow[]; callerRole: string }) {
  const [inviteState, invite] = useFormState<TeamState, FormData>(inviteStaff, null);
  const [rowState, rowAction] = useFormState<TeamState, FormData>(rowDispatch, null);

  const canInvite = invitableRoles(callerRole);
  const isOwner = callerRole === "owner";
  const activeOwners = rows.filter((r) => r.role === "owner" && r.status === "active").length;

  return (
    <div className="max-w-3xl">
      {canInvite.length > 0 && (
        <form action={invite} className="mb-6 rounded border border-line bg-surface px-3.5 py-3">
          <p className="text-[13px] font-medium text-ink">Invite someone</p>
          {inviteState && <div className="mt-2"><Notice kind={inviteState.ok ? "ok" : "error"}>{inviteState.message}</Notice></div>}
          <div className="mt-2 flex flex-wrap items-end gap-2">
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">Email</span>
              <input name="email" type="email" required placeholder="name@example.com" className={`${inputClass} w-64`} />
            </label>
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">Name</span>
              <input name="name" placeholder="Optional" className={`${inputClass} w-44`} />
            </label>
            <label className="text-[12px] text-ink-2">
              <span className="mb-1 block">Role</span>
              <select name="role" className={`${inputClass} w-40`} defaultValue={canInvite[0]}>
                {canInvite.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
              </select>
            </label>
            <Btn>Send invite</Btn>
          </div>
        </form>
      )}

      {rowState && <div className="mb-3"><Notice kind={rowState.ok ? "ok" : "error"}>{rowState.message}</Notice></div>}

      <div className="overflow-x-auto rounded border border-line">
        <table className="w-full min-w-[40rem] border-collapse text-[13px]">
          <thead>
            <tr className="border-b border-line text-left text-[12px] text-ink-3">
              <th className="px-3 py-2 font-medium">Name</th>
              <th className="px-3 py-2 font-medium">Email</th>
              <th className="px-3 py-2 font-medium">Role</th>
              <th className="px-3 py-2 font-medium">Status</th>
              <th className="px-3 py-2 font-medium">Last sign-in</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const lastOwner = r.role === "owner" && r.status === "active" && activeOwners <= 1;
              const canRemove =
                r.role !== "instructor" && !r.is_self && !lastOwner &&
                (isOwner || (callerRole === "manager" && r.role === "front_desk"));
              const canChange = isOwner && r.role !== "instructor" && !lastOwner;
              return (
                <tr key={r.staff_id} className="border-b border-line align-middle">
                  <td className="px-3 py-2 text-ink">{r.name ?? <span className="text-ink-3">—</span>}</td>
                  <td className="px-3 py-2 text-ink-2">{r.email}</td>
                  <td className="px-3 py-2">
                    {canChange ? (
                      <form action={rowAction} className="inline">
                        <input type="hidden" name="op" value="role" />
                        <input type="hidden" name="staff_id" value={r.staff_id} />
                        <select name="role" defaultValue={r.role}
                                className="rounded border border-line bg-surface px-1.5 py-1 text-[12px] text-ink"
                                onChange={(e) => {
                                  if (window.confirm(`Change ${r.email} to ${ROLE_LABEL[e.target.value]}?`)) {
                                    e.currentTarget.form?.requestSubmit();
                                  } else { e.currentTarget.value = r.role; }
                                }}>
                          <option value="owner">Owner</option>
                          <option value="manager">Manager</option>
                          <option value="front_desk">Front desk</option>
                        </select>
                      </form>
                    ) : (
                      <span className="text-ink-2">{ROLE_LABEL[r.role] ?? r.role}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-ink-2">{r.status === "invited" ? "Invited" : r.status === "active" ? "Active" : r.status}</td>
                  <td className="px-3 py-2 num text-ink-3">{r.last_sign_in_at ? new Date(r.last_sign_in_at).toLocaleDateString() : "—"}</td>
                  <td className="px-3 py-2 text-right">
                    {lastOwner ? (
                      <span className="text-[12px] text-ink-3">Only owner — add another before removing</span>
                    ) : canRemove ? (
                      <form action={rowAction} className="inline"
                            onSubmit={(e) => { if (!window.confirm(`Remove ${r.email}'s access?`)) e.preventDefault(); }}>
                        <input type="hidden" name="op" value="remove" />
                        <input type="hidden" name="staff_id" value={r.staff_id} />
                        <button className="text-[12px] text-coral underline underline-offset-2">Remove</button>
                      </form>
                    ) : r.is_self ? (
                      <span className="text-[12px] text-ink-3">You</span>
                    ) : r.role === "instructor" ? (
                      <span className="text-[12px] text-ink-3">On the Instructors page</span>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
