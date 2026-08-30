# STUDIIOR V1 — BUSINESS RULES

**Version:** 1.1 (reconstructed, patched for Decisions 1–11)
**Status:** Governs Modules 1, 3, 4 and 6. Blocks the booking transaction.

> **Reconstruction note.** Recovered from the roadmap session. Sections 2–5 and 8–15 are verbatim. Section 1, the back half of section 6, and sections 7.1–7.4 are marked **[RECONSTRUCTED]** — verify before implementing. Section 14 has been rewritten: those items are now settled, not open.

---

## 1. Time and timezone [RECONSTRUCTED]

- Everything is stored as `timestamptz` in UTC. Studio timezone governs all display and all "day" boundaries.
- "Today", "this week", "12 days since last visit" are all evaluated in studio local time.
- Recurring classes are defined in studio local time. A 7:00 AM class stays 7:00 AM across daylight saving transitions — occurrences are materialised by converting local time to UTC at generation, not by adding fixed intervals.
- If a DST transition makes a local time invalid or ambiguous, the occurrence is generated at the nearest valid time and flagged for staff review.
- Week boundaries follow `studio_settings.week_starts_on` (default Monday).

---

## 2. Booking

### 2.1 Eligibility gate

A booking attempt is evaluated in this order. The first failure stops the attempt and returns a specific reason — never a generic "cannot book".

1. Occurrence is `scheduled`, not cancelled, not in the past.
2. Booking window: `starts_at` is within `booking_window_days` from now. Plan-level override wins over studio default.
3. Booking cutoff: `starts_at` is at least `booking_cutoff_minutes` away. Default **0** — booking allowed right up to start time.
4. Waiver signed, if `require_waiver`.
5. Member status is `active`.
6. No existing live booking for this occurrence.
7. Daily limit: bookings for that studio-local day < `max_bookings_per_day`. Default **null** (unlimited).
8. Forward limit: live future bookings < `max_future_bookings`. Default **null**.
9. Plan restrictions: if the member is paying via a membership with `restrictions.class_type_ids`, the occurrence's class type must be in the list.
10. Capacity available, else waitlist.

### 2.2 Payment source resolution

When a member books, the system picks what pays for it — the member never chooses. Order:

| Priority | Source | Effect |
|---|---|---|
| 1 | Active unlimited membership covering this class type | Nothing consumed |
| 2 | Active limited membership with remaining period allowance | Consumes one period credit |
| 3 | Class pack credits, **soonest expiry first** | Consumes one pack credit |
| 4 | None of the above | Prompt for drop-in payment |

This order deliberately favours the member: their paid-for pack credits are preserved while a membership can cover the class. The resolved source is shown on the confirmation screen so it is never a surprise.

Credits are consumed **at booking time**, not at attendance.

### 2.3 Staff bookings and overrides

Staff (front desk and above) can book a member into a class that fails rules 2, 3, 7, 8, 9 or 10. Every override:

- requires selecting a reason,
- writes an `audit_logs` row with actor and reason,
- is visible on the booking record.

Overriding capacity is permitted — a walk-in for a full class is a real situation. `booked_count` may exceed `capacity`; the UI shows this as over-capacity rather than treating it as an error.

Rules 1 (past/cancelled class), 4 (waiver) and 6 (duplicate) are **not** overridable.

### 2.4 Comp bookings

Staff can book with `payment_source = 'comp'`. No credit consumed, no charge. Counts as attendance for challenges and milestones.

---

## 3. Cancellation

### 3.1 By the member

| Timing | Status | Credit | Fee | Spot released |
|---|---|---|---|---|
| Before `cancellation_cutoff_minutes` | `cancelled` | Returned | None | Yes |
| After cutoff | `late_cancelled` | Consumed if `late_cancel_consumes_credit` (default **true**) | Optional, default **none** | Yes |

Default cutoff: **720 minutes (12 hours)** before start.

A returned credit is restored to the exact ledger entry it came from, retaining its original expiry date. A credit cannot be resurrected past its expiry — if the pack has since expired, the credit is not returned and the member is told why.

Late cancellation still releases the spot and still triggers waitlist promotion (Decision 7). Penalising the member and holding the spot empty helps nobody.

### 3.2 By the studio

When staff cancel an occurrence:

- All bookings move to `cancelled`, all credits returned regardless of timing, all fees waived.
- Drop-in payments are **not** auto-refunded — refunding money is a deliberate act. The owner gets a task listing affected payments with one-click refund.
- All booked and waitlisted members notified immediately by email and push.
- The occurrence stays in the calendar with `status = 'cancelled'` — it is never deleted, because attendance history and reports depend on it.

### 3.3 Instructor substitution — PATCHED, Decision 2

Not a cancellation. The occurrence keeps its identity; `instructor_id` changes and `substitute_for` records the original.

Assigning a substitute **inside** the cancellation window is permitted, with friction:

- warns the acting staff member,
- requires a reason,
- writes an `audit_logs` row,
- notifies all booked members immediately.

Refusing the substitution outright just forces a cancelled class, which is worse for everyone.

**Free cancellation, narrow case only.** When a substitution is announced *after* the cancellation cutoff has already passed, booked members get a penalty-free cancellation for that occurrence. Governed by `studio_settings.sub_late_free_cancel`, default **on**. Three days' notice means normal policy applies; ninety minutes' notice means the member is not charged for a class they can no longer decide about.

### 3.4 No-shows

A finalisation job runs 30 minutes after each occurrence ends:

- `booked` with no check-in → `no_show`. Credit consumed if `no_show_consumes_credit` (default **true**).
- `booked` with a check-in → `attended`.
- Occurrence → `completed`.

Staff can correct a no-show to attended for 7 days afterwards. Correction returns the credit and triggers challenge and milestone re-evaluation.

---

## 4. Waitlist

### 4.1 Joining

- Available when the class is full, `waitlist_enabled` is true, and the member passes every eligibility rule except capacity.
- Position is strictly FIFO by join time. **No priority tiers in V1** — membership-based waitlist priority is a V2 item.
- **No credit is consumed on joining.** Credit is only taken if the member accepts a promotion.
- A member may leave the waitlist at any time, free, no penalty, no late-cancel logic.

### 4.2 Promotion

Triggered by: a booking cancellation, a capacity increase, or a no-show correction that frees a seat.

1. Find the lowest `waitlist_position` still waiting.
2. Create a `waitlist_offers` row with `expires_at`.
3. Notify by email and push immediately.
4. On accept: re-run the eligibility gate (their membership may have lapsed since), consume credit, booking becomes `booked`, offer marked accepted.
5. On decline or expiry: offer closed, cascade to the next member, repeat.

The seat is **held** for the offered member for the duration of the offer. It is not released to general booking. Holding is what makes the offer meaningful.

### 4.3 Offer window

`waitlist_offer_window_minutes`, default **120**, but always clamped:

```
effective_window = min(
  waitlist_offer_window_minutes,
  minutes_until(starts_at) - waitlist_cutoff_minutes
)
```

If `effective_window` is under 15 minutes, no offer is made and the seat opens to general booking instead. A ten-minute window at 6 AM is not a real opportunity.

### 4.4 Cutoff and expiry

- No promotions inside `waitlist_cutoff_minutes` of start. Default **60**.
- At that point every remaining waitlist entry is closed with a "didn't get in this time" notification, and the seat opens to general booking.
- Without SMS, a member on iOS who hasn't installed the PWA receives email only. The 120-minute default reflects that. If waitlist conversion is poor with design partners, the fix is member-controlled auto-accept, which is a V2 feature.

---

## 5. Capacity

- Occurrence capacity defaults from the series, which defaults from the room, which defaults from the class type.
- Increasing capacity immediately runs a waitlist promotion sweep.
- Capacity **cannot** be reduced below current `booked_count`. Staff must cancel specific bookings first — the system never silently picks who loses their spot.
- Over-capacity from staff overrides is displayed, not corrected.

---

## 6. Credits

- Granted on purchase. Expiry = purchase date + `validity_days`, or never if null.
- Recurring plan allowances reset at each billing period boundary. Unused allowance **does not roll over** (Decision 3).
- Balance is derived from `credit_ledger`, never edited in place. `memberships.credits_remaining` is a cache written in the same transaction as the ledger row. [RECONSTRUCTED from here]
- Every ledger row carries `balance_after`, so any balance is reconstructable at any point in history without replaying the whole ledger.
- Consumption order across multiple packs: soonest expiry first (Decision 1).
- Manual adjustment is owner or manager only, requires a reason, and writes both a ledger row with `reason = 'manual'` and an audit row.
- Expiry runs nightly: credits past `expires_at` are written off with `reason = 'expiry'` and a negative delta. Members are warned 7 days before.
- Balance can never go negative. A booking that would take it below zero falls through to the next payment source.

---

## 7. Memberships

### 7.1 Purchase and activation [RECONSTRUCTED]

- Purchase creates the `memberships` row plus a Stripe subscription on the studio's **connected** account.
- `price_cents` is snapshotted at purchase. Later plan price changes never alter existing memberships.
- Recurring plans grant `credits_per_period` at each period boundary. Packs grant `credits` once, expiring after `validity_days`.
- Trials are a `plan_type`, not a flag. They convert or expire, and conversion is a status change on the same row.

### 7.2 Renewal [RECONSTRUCTED]

- Driven by Stripe webhooks on the connected account, never by a local clock.
- `invoice.paid` advances the period and grants the new allowance. Nothing is granted optimistically before payment confirms.
- Every status change writes a `membership_events` row. That table is the audit trail for anything a member disputes.

### 7.3 Failed payment — PATCHED, Decision 4

- `invoice.payment_failed` moves the membership to `past_due` and starts the grace period.
- Grace period is `studio_settings.payment_grace_days`, default **7**, range 0–30. Zero means blocked immediately.
- **Blocked means no new bookings.** Existing bookings stand. Cancelling classes a member already booked because their bank flagged a transaction is how you lose a member who did nothing wrong.
- Member is emailed on day 0, day 3 and day 6 with a Stripe update link. The owner sees it in the Morning Brief on day one.
- At the end of grace with no successful payment, the membership moves to `cancelled` and the owner is notified.

### 7.4 Freeze [RECONSTRUCTED]

- Member requests, owner or manager approves. Not self-serve.
- Freeze pauses billing and access for the requested window, capped by `max_freeze_days` on the plan.
- `freeze_days_used` accumulates against the plan cap across the membership's life, not per request.
- Frozen memberships cannot book. Existing future bookings inside the freeze window are cancelled with credits returned.

### 7.5 Cancellation

- Cancel at period end is the default: access continues to `current_period_end`, no refund, `cancel_at` set.
- `cancellation_notice_days` on the plan governs how far ahead notice must be given.
- Immediate cancellation with refund is an owner-only action requiring a reason.

### 7.6 Upgrade and downgrade

- Handled through Stripe proration.
- Access changes immediately. Period allowance is recalculated pro rata for the remainder of the period.
- Downgrade takes effect at the next period boundary if it would reduce allowance below what the member has already consumed.

---

## 8. Check-in and attendance

- Check-in window opens **60 minutes before** start and closes **30 minutes after** end.
- Methods: QR scan by member, staff check-in from the roster, kiosk.
- Late arrival still counts as attended.
- Walk-in: staff create booking and check-in in one action, with capacity override if needed.
- A check-in updates `members.last_visit_at` and `lifetime_visits`, and triggers milestone and challenge evaluation synchronously — the member should see their achievement before they leave the building.

### Streak definition — Decision 5

A streak is **consecutive weeks with at least one attended class**, using the studio's week start. Not consecutive days.

Daily streaks punish rest days, which is the opposite of what a Pilates or yoga studio wants to encourage, and they break constantly, which makes the number meaningless. Weekly streaks reward the habit that actually predicts retention. Recomputed nightly and after each check-in.

---

## 9. Challenges

### 9.1 What counts as progress

**Member challenges.** An `attended` check-in on an occurrence that starts within the challenge's date range and matches `class_type_ids` if the challenge filters by type. One progress event per booking, enforced by unique constraint. Late cancels and no-shows never count. A no-show later corrected to attended does count, and progress is re-evaluated.

**Instructor challenges — PATCH, Decisions 10 and 11.** A `completed` occurrence where the instructor was assigned. One progress event per occurrence, enforced by unique constraint. A cancelled occurrence never counts. A substitution credits whoever actually taught it — the instructor on the row at completion, not `substitute_for`.

### 9.2 Joining

Progress counts qualifying attendance **from the challenge start date**, regardless of when the member joined. A member who joins on day 10 having attended four classes starts at four. Late joiners aren't punished for signing up late, and the leaderboard reflects actual behaviour.

`join_deadline` is **mandatory** (Decision 6) and must fall between `starts_on` and `ends_on`. Joining after it is blocked.

### 9.3 Completion

When `progress >= goal_value`: `completed_at` set, achievement awarded, participant notified, timeline event written.

Progress beyond the goal keeps accumulating for leaderboard ordering.

### 9.4 Leaderboard ordering

1. Higher progress first.
2. Tie → earlier `completed_at`.
3. Still tied → earlier `last_progress_at`.
4. Still tied → earlier `joined_at`.

Fully deterministic. Recomputable from `challenge_progress_events` at any time.

**Member and instructor leaderboards never merge.** Ordering runs per `audience`.

### 9.5 Streak challenges

Goal is consecutive weeks (section 8's definition) within the challenge window. Breaking the streak resets progress to the current run, not to zero history — the member sees "3 weeks" not "you failed".

### 9.6 Instructor rewards — PATCH, Decision 10

`reward_description` is descriptive text, fulfilled by the studio manually. Nothing in the challenge system resolves to money owed. Anything that multiplies classes taught by a rate is compensation and belongs in Wave 3 payroll, not here.

---

## 10. Milestones and achievements

System-defined, awarded once per member ever:

| Trigger | Thresholds |
|---|---|
| Visit count | 1, 10, 25, 50, 100, 250, 500 |
| Weekly streak | 4, 12, 26, 52 |
| Challenge completed | first, 3rd, 10th |
| Membership anniversary | each year |
| Birthday | annually, not an achievement — a notification and an AI insight |

Count-based triggers evaluate on check-in. Date-based triggers evaluate in the nightly job.

Studios can add custom achievement definitions but cannot edit system ones — otherwise the AI's "Emma is about to reach her 100th class" insight becomes unreliable.

**Instructor achievements (PATCH, Decision 10):** classes taught at 10, 50, 100, 250, 500, and weekly teaching streaks. Same table shape, `audience = 'instructor'`.

---

## 11. AI generation rules

- Generation runs nightly at `morning_brief_send_at` minus 30 minutes, in studio time.
- **Maximum 5 insights per brief.** More than that and the owner stops reading, which defeats the entire feature.
- Deduplication: one insight per `(type, subject, date)`. If the same subject and type was actioned or dismissed within the last 7 days, it is suppressed.
- Every insight must carry a valid `action_type` and `action_payload`. An insight without a working button is a bug and fails QA.
- **Nothing is ever sent automatically.** AI drafts; the owner approves. This is a hard architectural rule and it should never be softened for convenience.

### Insight thresholds

| Type | Trigger |
|---|---|
| `retention_risk` | Active member, days since last visit > 2× their own median gap, minimum 10 days |
| `milestone_upcoming` | Within 1 visit of a threshold, or anniversary/birthday within 7 days |
| `class_underfilled` | Occurrence in next 7 days below 40% capacity where the series historically averages above 70% |
| `class_overfilled` | Series at ≥95% for 3 consecutive weeks |
| `payment_failed` | Any membership in `past_due` |
| `new_member_stalled` | Joined ≤30 days ago, fewer than 2 visits, no booking in next 7 days |
| `challenge_opportunity` | ≥5 members matching a template's profile and no active challenge |

Thresholds are constants in config, not magic numbers in queries — design partners will move them.

---

## 12. Notification timing

Full matrix comes in its own document. The rules that belong here:

| Event | When |
|---|---|
| Booking confirmation | Immediate |
| Class reminder | `reminder_hours_before`, default 12 |
| Waitlist offer | Immediate on promotion |
| Waitlist closed | At the promotion cutoff |
| Class cancelled | Immediate |
| Instructor substituted | Immediate |
| Payment failed | Immediate, then day 3 and day 6 of grace |
| Credit expiry warning | 7 days before |
| Milestone earned | Immediate on check-in |
| Morning brief | `morning_brief_send_at` |

Every notification carries a deterministic dedupe key so a retried job cannot double-send.

---

## 13. Overrides and audit

Overridable by front desk and above: booking window, cutoff, daily limit, forward limit, plan restrictions, capacity, late-cancel penalty, no-show correction.

Owner or manager only: refunds, manual credit adjustment, immediate membership cancellation, freeze approval, capacity reduction.

Never overridable: booking a past or cancelled class, duplicate booking, unsigned waiver, negative credit balance, automatic sending of AI-drafted messages.

Every override writes an audit row with actor, reason and before/after state.

---

## 14. Settled decisions — was "needing your sign-off"

All seven original items are now closed. Recorded here so nobody reopens them by accident.

| # | Rule | Where |
|---|---|---|
| 1 | Payment source resolution — soonest expiry first among packs, packs preserved behind memberships | §2.2 |
| 2 | Substitution inside the window permitted with friction; free cancellation only when announced after the cutoff | §3.3 |
| 3 | No credit rollover between periods | §6 |
| 4 | Failed payment grace is a studio setting, default 7 days, blocks new bookings only | §7.3 |
| 5 | Streaks are weekly, not daily | §8 |
| 6 | Challenge progress counts from challenge start; `join_deadline` mandatory | §9.2 |
| 7 | Late cancellation releases the seat and promotes the waitlist | §3.1 |

Decisions 8–12 (owner count, dormant locations, instructor availability, instructor recognition, challenge audience, plan credit columns) are recorded in the decision log and reflected in the data model.

---

## 15. Still open

1. **Stripe onboarding time-to-complete.** Connect Standard OAuth requires the studio to have or create a Stripe account during setup. Time it with a design partner against the one-hour target.
2. **Member identity across studios.** Same email can be a member of two studios; separate accounts per subdomain, no policy joins them.
3. **Archived-member retention policy.** How long before GDPR hard delete.
4. **Front-desk refund permissions.** Currently no refund. Money leaving the studio needs a second pair of hands.
5. **Reschedule inside the cancellation window.** Whether a same-week move to another occurrence is treated more leniently than a plain cancel. Affects credit consumption and seat release.
