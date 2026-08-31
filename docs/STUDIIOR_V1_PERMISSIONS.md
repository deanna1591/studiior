# STUDIIOR V1 — PERMISSIONS MATRIX

**Version:** 1.1 (reconstructed, patched for Decisions 9 and 10)
**Status:** Becomes the RLS policies directly. Blocks migration 001.

> **Reconstruction note.** Recovered from the roadmap session. Sections 2–5 and 9–16 are verbatim. Sections 6, 7 and 8 are marked **[RECONSTRUCTED]** — rebuilt from the data model, business rules and the recovered footnotes. Verify before writing policies.

---

## 1. Scope notes

**Manager marketing scope.** V1 excludes the email builder, SMS builder, landing pages and the affiliate system. A Manager's marketing scope in V1 means: create and run challenges, and approve AI-drafted member messages. Nothing more, because nothing more exists yet.

**Front Desk "Payments."** Read as *taking* payment — selling a membership, a pack, a drop-in. Not refunding. Business Rules §13 puts refunds with Owner and Manager, and money leaving the studio should need a second pair of hands.

---

## 2. Legend

✅ full · 👁 read only · ⚠️ conditional, see note · ❌ none

Columns: **O** Owner · **M** Manager · **I** Instructor · **FD** Front Desk · **Mem** Member

---

## 3. Studio & configuration

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| View studio profile | ✅ | ✅ | 👁 | 👁 | ⚠️¹ |
| Edit studio profile, branding, PWA identity | ✅ | ❌ | ❌ | ❌ | ❌ |
| Connect / disconnect Stripe | ✅ | ❌ | ❌ | ❌ | ❌ |
| Edit booking & cancellation settings | ✅ | ✅ | ❌ | ❌ | ❌ |
| Edit waiver text | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage rooms | ✅ | ✅ | ❌ | ❌ | ❌ |
| View audit log | ✅ | ❌ | ❌ | ❌ | ❌ |

¹ Public fields only — name, logo, address, timezone — via a restricted view.

---

## 4. Staff & instructors

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| Invite staff | ✅ | ⚠️² | ❌ | ❌ | ❌ |
| Change a role | ✅ | ❌ | ❌ | ❌ | ❌ |
| Deactivate staff | ✅ | ⚠️² | ❌ | ❌ | ❌ |
| Create / edit instructor records | ✅ | ✅ | ⚠️³ | ❌ | ❌ |
| View instructor list | ✅ | ✅ | ✅ | ✅ | 👁⁴ |
| Submit / edit own availability **(PATCH)** | ✅ | ✅ | ✅ | ❌ | ❌ |
| View another instructor's availability **(PATCH)** | ✅ | ✅ | ❌ | ❌ | ❌ |

² Manager may invite and deactivate Instructor and Front Desk only. Never another Manager, never an Owner.
³ Own record: bio, photo, certifications. Not their own role, not another instructor.
⁴ Name, photo, bio only.

**Owner count.** Minimum one per studio, no maximum. The last Owner cannot be removed or demoted.

---

## 5. Members & CRM

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| List & search members | ✅ | ✅ | ⚠️⁵ | ✅ | ❌ |
| View member profile | ✅ | ✅ | ⚠️⁵ | ⚠️⁶ | ⚠️⁷ |
| Create member | ✅ | ✅ | ❌ | ✅ | — |
| Edit member details | ✅ | ✅ | ❌ | ✅ | ⚠️⁷ |
| Archive member | ✅ | ✅ | ❌ | ❌ | ❌ |
| View lifetime value / revenue fields | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage tags | ✅ | ✅ | ❌ | ✅ | ❌ |
| View / edit goals | ✅ | ✅ | 👁 | 👁 | ⚠️⁷ |
| View journey timeline | ✅ | ✅ | ⚠️⁸ | ✅ | ⚠️⁷ |
| Export members | ✅ | ✅ | ❌ | ❌ | ❌ |
| Import members | ✅ | ✅ | ❌ | ❌ | ❌ |

⁵ **Instructor member quick-view** only: photo, preferred name, attendance summary, goals, pinned notes, first-timer and birthday flags. No contact details, no financial data, no full CRM. Searchable across the studio, because an instructor needs to look someone up before class.
⁶ Front desk sees everything except revenue analytics and lifetime value.
⁷ Own record only.
⁸ Attendance, challenge and achievement events only. No payment or membership events.

---

## 6. Scheduling [RECONSTRUCTED]

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| View calendar | ✅ | ✅ | ⚠️⁹ | ✅ | ⚠️¹⁰ |
| Create / edit class types | ✅ | ✅ | ❌ | ❌ | ❌ |
| Create single class | ✅ | ✅ | ❌ | ❌ | ❌ |
| Create / edit recurring series | ✅ | ✅ | ❌ | ❌ | ❌ |
| Move or reschedule a class | ✅ | ✅ | ❌ | ❌ | ❌ |
| Cancel a class | ✅ | ✅ | ❌ | ❌ | ❌ |
| Assign or change instructor | ✅ | ✅ | ❌ | ❌ | ❌ |
| Assign a substitute | ✅ | ✅ | ❌ | ❌ | ❌ |
| Change capacity | ✅ | ✅ | ❌ | ⚠️¹¹ | ❌ |
| Write class notes | ✅ | ✅ | ⚠️⁹ | ❌ | ❌ |

⁹ Own classes only.
¹⁰ Scheduled occurrences in their own studio, within the booking window.
¹¹ Override for a walk-in, per Business Rules §2.3. Not a permanent capacity edit.

**Instructors do not schedule.** Decision 9 gives them availability submission only. Owner and Manager own the timetable. Assigning an instructor outside their stated availability is permitted with a warning, never blocked, and availability edits never retroactively unassign anyone.

---

## 7. Bookings & waitlist [RECONSTRUCTED]

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| Book a member into a class | ✅ | ✅ | ❌ | ✅ | ⚠️¹² |
| Cancel a booking | ✅ | ✅ | ❌ | ✅ | ⚠️¹² |
| Override the eligibility gate | ✅ | ✅ | ❌ | ✅ | ❌ |
| Waive a late-cancel fee | ✅ | ✅ | ❌ | ✅ | ❌ |
| Comp a booking | ✅ | ✅ | ❌ | ✅ | ❌ |
| Join / leave waitlist | ✅ | ✅ | ❌ | ✅ | ⚠️¹² |
| View waitlist order | ✅ | ✅ | 👁 | ✅ | 👁 |
| Reorder the waitlist | ❌ | ❌ | ❌ | ❌ | ❌ |
| See who else is booked | ✅ | ✅ | ✅ | ✅ | ❌ |

Chapter 7 excludes the social layer, so "who's going" is a V2 question for members.
¹² Own bookings only.

Waitlist order is strictly FIFO and nobody can reorder it, including the Owner. Business Rules §4.1 — a queue people believe in is worth more than a queue that can be adjusted.

---

## 8. Check-in & attendance [RECONSTRUCTED]

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| Check a member in | ✅ | ✅ | ✅ | ✅ | ⚠️¹³ |
| View class roster | ✅ | ✅ | ⚠️⁹ | ✅ | ❌ |
| Correct a no-show | ✅ | ✅ | ❌ | ✅ | ❌ |
| Create walk-in booking + check-in | ✅ | ✅ | ❌ | ✅ | ❌ |
| View own attendance history | — | — | — | — | ✅ |

¹³ Self check-in by presenting a rotating QR code, scanned at the desk.

---

## 9. Memberships & payments

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| View membership plans | ✅ | ✅ | ❌ | ✅ | 👁¹⁴ |
| Create / edit plans | ✅ | ✅ | ❌ | ❌ | ❌ |
| Sell membership / pack / drop-in | ✅ | ✅ | ❌ | ✅ | ⚠️¹⁵ |
| View a member's membership | ✅ | ✅ | ❌ | ✅ | ⚠️¹⁶ |
| Approve freeze | ✅ | ✅ | ❌ | ❌ | ❌ |
| Request freeze | — | — | — | — | ✅ |
| Cancel membership at period end | ✅ | ✅ | ❌ | ❌ | ✅ |
| Cancel immediately with refund | ✅ | ❌ | ❌ | ❌ | ❌ |
| Upgrade / downgrade | ✅ | ✅ | ❌ | ⚠️¹⁷ | ✅ |
| Take a payment | ✅ | ✅ | ❌ | ✅ | ✅ |
| Issue refund | ✅ | ✅ | ❌ | ❌ | ❌ |
| Adjust credits manually | ✅ | ✅ | ❌ | ❌ | ❌ |
| View payment history | ✅ | ✅ | ❌ | ⚠️¹⁸ | ⚠️¹⁶ |
| Manage promo codes | ✅ | ✅ | ❌ | ❌ | ❌ |
| Sell / redeem gift card | ✅ | ✅ | ❌ | ✅ | ✅ |
| Update card details | ✅ | ✅ | ❌ | ❌ | ✅ |

¹⁴ `visibility = 'public'` plans only.
¹⁵ For themselves.
¹⁶ Own only.
¹⁷ Upgrade yes, downgrade no — downgrades touch proration and commitment terms.
¹⁸ Individual transactions to answer a member's question. Not studio-wide revenue.

Instructors have no access to any of this. Enforced by RLS policy, not by hiding menu items.

---

## 10. Challenges

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| View challenges | ✅ | ✅ | ✅ | ✅ | ✅ |
| Create / edit challenge | ✅ | ✅ | ❌ | ❌ | ❌ |
| Publish / end challenge | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage templates | ✅ | ✅ | ❌ | ❌ | ❌ |
| Enrol a member | ✅ | ✅ | ❌ | ✅ | ⚠️¹⁹ |
| Adjust progress manually | ✅ | ✅ | ❌ | ❌ | ❌ |
| View leaderboard | ✅ | ✅ | ✅ | ✅ | ✅ |
| Award achievement manually | ✅ | ✅ | ❌ | ❌ | ❌ |
| Join an instructor challenge **(PATCH)** | ✅ | ✅ | ✅ | ❌ | ❌ |

¹⁹ Self-enrol.

**Audience separation (PATCH, Decision 11).** Member and instructor leaderboards are separate views over the same tables, filtered by `audience`. An instructor viewing a member challenge sees the leaderboard, not the member CRM behind it.

---

## 11. Analytics & AI

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| Revenue reports | ✅ | ✅ | ❌ | ❌ | ❌ |
| Attendance & class reports | ✅ | ✅ | ⚠️²⁰ | 👁 | ❌ |
| Member & retention reports | ✅ | ✅ | ❌ | ❌ | ❌ |
| Instructor performance | ✅ | ✅ | ⚠️²⁰ | ❌ | ❌ |
| Export reports | ✅ | ✅ | ❌ | ❌ | ❌ |
| View AI Morning Brief | ✅ | ✅ | ❌ | ❌ | ❌ |
| Action / dismiss an insight | ✅ | ✅ | ❌ | ❌ | ❌ |
| Send an AI-drafted message | ✅ | ✅ | ❌ | ❌ | ❌ |
| View own classes-taught count **(PATCH)** | ✅ | ✅ | ✅ | ❌ | ❌ |

²⁰ Own classes only — their occupancy, their attendance. **Never a comparison against other instructors.** Analytics for instructors is a coaching tool, not a leaderboard. Decision 10 adds a personal classes-taught count and streak; it does not add cross-instructor ranking. If a public staff leaderboard is ever built, it is a studio setting defaulting to off.

---

## 12. Notifications

| Action | O | M | I | FD | Mem |
|---|---|---|---|---|---|
| Receive operational alerts | ✅ | ✅ | ⚠️²¹ | ⚠️²¹ | — |
| Manage own notification prefs | ✅ | ✅ | ✅ | ✅ | ✅ |
| Send a message to a member | ✅ | ✅ | ❌ | ✅ | — |
| Broadcast to a segment | ✅ | ✅ | ❌ | ❌ | — |

²¹ Class-level only: cancellations and substitutions affecting them. No payment or churn alerts.

---

## 13. The instructor app — five screens (PATCHED)

> **Changed from three.** Decision 9 adds availability submission; Decision 10 adds personal stats. The original text read *"Not in V1: availability submission, substitution requests, payroll, cross-instructor performance."* The first item is now in scope and the fourth is partially in scope.

Inside the same staff app, mobile-first:

1. **My Schedule** — their week, today first.
2. **Class Roster** — who's booked, first-timer and birthday badges, pinned notes, one-tap check-in.
3. **Member Quick View** — photo, preferred name, attendance summary, goals, notes. Nothing financial.
4. **My Availability** — recurring weekly pattern plus dated exceptions. Write access to own rows only.
5. **My Stats** — classes taught, weekly teaching streak, personal targets, badges, active instructor challenges. No comparison to other instructors.

**Still not in V1:** substitution requests, payroll, pay rates, cross-instructor performance comparison. Those remain in the Chapter 18 parking lot.

Screens 1–3 reuse roster and check-in logic already built for Front Desk. Screens 4–5 are new work.

---

## 14. Field-level restrictions

Some fields must be denied inside tables a role can otherwise read. Implemented as restricted views, not client-side hiding:

| Field | Denied to |
|---|---|
| `members.lifetime_visits` revenue equivalents, LTV | Instructor |
| `members.email`, `phone`, `address`, `emergency_contact` | Instructor²² |
| `class_occurrences` revenue estimates | Instructor |
| `member_notes` where `managers_only` | Instructor, Front Desk |
| `payments.*`, `memberships.*`, `credit_ledger.*` | Instructor |
| `studios.stripe_account_id` | Everyone but Owner |
| `instructor_availability` of other instructors **(PATCH)** | Instructor, Front Desk |

²² Emergency contact is visible to an instructor **during** a class they are teaching — a genuine safety need — surfaced through the roster, not the member record.

---

## 15. Implementation notes

- Every rule is an RLS policy. The UI hides what a role can't do, but the database is what enforces it. **A permission that exists only in React is not a permission.**
- Role is resolved via `auth_role_in(studio_id)` from the data model, evaluated per request. Never trusted from the client, never cached in a JWT claim that outlives a role change.
- Conditional permissions (⚠️ rows) are policy predicates, not application `if` statements — instructor roster scoping, member own-record scoping and Manager staff limits all live in SQL.
- Overrides write to `audit_logs` with actor and reason, per Business Rules §13.
- Members authenticate on their studio's subdomain. **A person who is a member of two studios has ONE account and two member records** — corrected, see below.

> **Correction (migration 027).** This line previously read "has two accounts, and no policy anywhere joins them". Neither half was true of the schema. `auth.users` carries `users_email_partial_key`, a global unique index on email, so one email is one account across the whole project and two accounts would require the person to use two different email addresses — not something a studio can ask a walk-in for. And `auth_member_studios()` is `select studio_id from members where user_id = auth.uid()`: it returns a *set*, and is precisely a policy that joins them.
>
> What is true, and what the code now enforces: **one login, many memberships, each scoped by subdomain.** A member row is per studio; the app resolves which one from the host, never by assuming there is only one. Studio A's members, classes and payments stay invisible from studio B because every policy is scoped by `studio_id` — what a person can reach across studios is their own two records, which is not a leak.
>
> The old wording was not merely inaccurate: `getMemberContext()` selected the member row with `.maybeSingle()`, so the second membership made the query error and the member PWA showed "no studio access" to anyone who joined a second studio.

---

## 16. Open items

1. **Instructor member search scope.** Currently studio-wide. Narrowing it to today's roster would be safer but breaks the "look someone up before class" case.
2. **Front-desk refunds.** Currently denied. Revisit if design partners find it too restrictive in practice.
3. **Archived-member retention.** How long before GDPR hard delete, and who can trigger it.
4. **Instructor substitution requests.** Not in V1. If added, needs a sixth screen and an approval queue for Owner and Manager.
