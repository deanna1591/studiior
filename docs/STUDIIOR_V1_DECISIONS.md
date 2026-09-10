# STUDIIOR V1 — DECISION LOG

**Canonical.** Every entry here is settled. If code contradicts this file, the code is wrong. If you think an entry is wrong, change it here first with a reason, then change the code.

**Source of truth above this file:** `docs/STUDIIOR_PRODUCT_BIBLE.md`. Note its per-chapter **MVP Scope** sections — Ch. 4, Ch. 5, 6.23, Ch. 7, 8.18, Ch. 10, Ch. 12 — which is where scope actually lives. The earlier citation here ("Ch. 8 seven modules, Ch. 7 exclusions, Ch. 9 roles, Ch. 20 scope test") pointed at chapters that either say something else or do not exist; roles are in `STUDIIOR_V1_PERMISSIONS.md`.

---

## 1 — Payment source resolution: soonest expiry first

Booking resolves what pays for it in this order: unlimited membership covering the class type, then limited membership with remaining period allowance, then class pack credits soonest-expiry-first, then prompt for drop-in.

Deliberately favours the member — their paid-for pack credits are preserved while a membership can cover the class. Some studios expect the reverse so packs get used before they expire. The resolved source is shown on the confirmation screen so it is never a surprise.

Credits are consumed at booking time, not at attendance.

**Where:** Business Rules §2.2. **Status:** settled.

---

## 2 — Instructor substitution inside the cancellation window

Permitted, with friction: warns, requires a reason, writes to the audit log, notifies booked members immediately. Refusing outright just forces a cancelled class, which is worse for everyone.

Members get a penalty-free cancellation **only** when the substitution is announced after the cancellation cutoff has already passed. Studio setting `sub_late_free_cancel`, default on. Three days' notice means normal policy. Ninety minutes' notice means the member isn't charged for a class they can no longer decide about.

**Where:** Business Rules §3.3. **Status:** settled.

---

## 3 — No credit rollover between periods

Recurring plan allowances reset at each billing period boundary. Unused allowance is lost.

**Where:** Business Rules §6. **Status:** settled.

---

## 4 — Failed payment grace period

Studio setting `payment_grace_days`, default 7, range 0–30. Zero means blocked immediately. Seven covers Stripe's retry cycle, so most cards recover before anyone notices.

**Blocked means no new bookings. Existing bookings stand.** Cancelling classes someone already booked because their bank flagged a transaction is how you lose a member who did nothing wrong.

Member emailed day 0, 3 and 6 with a Stripe update link. Owner sees it in the Morning Brief on day one.

**Where:** Business Rules §7.3. **Status:** settled.

---

## 5 — Streaks are weekly, not daily

A streak is consecutive weeks with at least one attended class, using the studio's week start.

Daily streaks punish rest days, which is the opposite of the habit a Pilates or yoga studio wants to build, and they break constantly, which makes the number meaningless.

**Where:** Business Rules §8. **Status:** settled.

---

## 6 — Challenge join deadlines are mandatory

`join_deadline` is `not null` and must fall between `starts_on` and `ends_on`.

Progress counts qualifying attendance from the challenge start date regardless of when the member joined. Someone who joins on day 10 having attended four classes starts at four.

**Where:** Business Rules §9.2. **Status:** settled.

---

## 7 — Late cancellation releases the seat

A late cancel is penalised per studio policy but still frees the spot and still triggers waitlist promotion. Penalising the member and holding the spot empty helps nobody.

**Where:** Business Rules §3.1. **Status:** settled.

---

## 8 — Owner count, and the dormant locations table

Minimum one Owner per studio, no maximum. The last active Owner cannot be removed or demoted. Enforced by trigger `guard_last_owner`, not application code.

One location per studio in V1. `locations` ships in migration 001 with exactly one row per studio, no UI and no multi-location logic, with `rooms`, `class_series` and `class_occurrences` parented to `location_id` rather than `studio_id` directly. A foreign key, not a feature. Retrofitting it later means rewriting every scheduling query and every RLS policy against live studio data.

Recruit single-location design partners deliberately — a two-location owner will spend the pilot asking for combined reporting and you'll learn nothing about whether the core product works.

**Where:** Data Model §3, migration 001. **Status:** settled.

---

## 9 — Instructors submit availability; they do not schedule

Instructors can submit and edit their own teaching availability. They cannot create, edit, move or delete classes. The timetable stays with Owner and Manager.

**Availability does not retroactively invalidate assignments.** Once an instructor is assigned to an occurrence, later edits to their availability do not unassign them, do not flag the occurrence, and do not notify anyone. Availability is an input to future assignment only. Without this, an instructor can quietly edit themselves out of a class they already agreed to teach and the studio finds out at 6am.

Assigning an instructor outside their stated availability is **permitted with a warning, never blocked**. Studios override availability constantly, and a hard block gets worked around by not using the feature.

New instructor screen: My Availability. New admin panel inside the scheduling flow.

**Where:** Data Model §5, Permissions §4 and §6. **Status:** settled.

---

## 10 — Instructor recognition is in V1; compensation is not

In: classes taught, weekly teaching streaks, personal targets, badges, instructor challenges. Reuses the Module 6 engine with a different participant type.

Out: anything that resolves to money owed — per-class rates, bonus thresholds, accrual, payout, payroll export. Remains Wave 3.

**Boundary test.** If a feature's output is a number an instructor could reasonably expect to be paid, it's compensation and out of scope. Classes taught this month is recognition. Classes taught multiplied by anything is compensation.

**Leaderboard caution.** Ranking instructors publicly by classes taught rewards whoever has the most open calendar, which in a small studio correlates with having the fewest other commitments rather than teaching quality. Ship personal metrics first; treat a public staff leaderboard as a studio setting, default off.

New instructor screen: My Stats. Instructor rewards are descriptive text, fulfilled manually.

**Where:** Business Rules §9.6 and §10, Permissions §11 and §13. **Status:** settled.

---

## 11 — Challenges are audience-typed at the schema level

`challenge_audience` enum (`member`, `instructor`) on challenges, templates and achievement definitions. `challenge_participants` and `challenge_progress_events` carry both `member_id` and `instructor_id`, nullable, with a check constraint that exactly one is set, plus partial unique indexes on each.

Same reasoning as the dormant `locations` table: one enum column and one indirection now, versus a data migration across participation, progress and reward tables while the feature is live.

Member and instructor leaderboards never merge. Ordering runs per audience.

Rewards must be audience-aware — an instructor cannot redeem a free class credit against a plan they do not hold.

**Considered and rejected:** a polymorphic `participant_id` with no foreign key. Simpler to write, gives up referential integrity.

**Where:** Data Model §8, migration 001. **Status:** settled. Blocked migration 001.

---

## 12 — `credits` is pack-only, `credits_per_period` is recurring-only

`membership_plans.credits` is the size of a bundle bought once: a ten-class pack has `credits = 10`. It is null on every other plan type.

`membership_plans.credits_per_period` is an allowance that resets at each billing boundary. It is null on every non-recurring type, and **null on a recurring plan means unlimited**. That is where the unlimited semantics live; they were previously annotated on `credits`, which implied a recurring plan could carry a bundle size.

There is no lifetime-cap concept in V1. A recurring plan is either unlimited or capped per period. "Unlimited but only 200 classes ever" is not a thing a studio sells, and inventing a column for it costs a data migration to remove later.

This is what `book_class()` has always done. Its §2.2 resolution reads `credits_per_period` and `memberships.credits_remaining`, and never reads `membership_plans.credits` at all — the pack grant reaches a booking through `credits_remaining`, not through the plan.

The ambiguity mattered because two columns describing one concept is exactly how a plan ends up disagreeing with what the booking function reads. A recurring plan with `credits = 8` and `credits_per_period = null` looks capped in the admin screens and resolves as **unlimited** at booking time, and nobody finds out until a member takes their ninth class of the month for free. The schema now refuses to store that row.

**Considered and rejected:** collapsing the two into one `credits` column with the meaning switched by `type`. Fewer columns, but every read site would have to know the type to know what the number means, and the null-means-unlimited case gets more confusing rather than less.

**Where:** Data Model §7, Business Rules §2.2, migration 010. **Status:** settled.

---

## 14 — Member Health Score is a band with a reason, not a number

## Why a band and not a number

A score of 68 invites the owner to argue with the number, and gives them nothing to do. "Was coming twice a week, hasn't been in 16 days" is a fact they can act on before lunch. The owner already knows their members better than any model will; the product's job is to surface the fact they missed, not to rank people.

A number also implies a precision the data cannot support. Thirty members and eighteen months of attendance is not enough to calibrate a hundred-point scale, and a false 68 is worse than an honest band.

---

## The five signals

### 1. Rhythm deviation — primary

Current visit frequency measured against **that member's own established baseline**, never against a studio average.

- Baseline: median gap between visits over the member's history, minimum 6 visits to establish.
- Fires when the current gap exceeds 2× baseline, floor of 10 days.
- Reason names both halves: the old rhythm and the current gap.

**This is the signal no competitor surfaces.** Every platform reports days-since-last-visit, which is a lagging indicator: by the time it is high, the member has already left mentally. Rhythm deviation catches someone who is *still attending* but has halved their frequency. They remain "active" in every other system in the market. This requires attendance history and the credit ledger in one place, which is what the schema gives.

### 2. Booking-to-attendance drift

A member who keeps booking but has started late-cancelling or no-showing is signalling before they stop booking. Intent persists; follow-through is going.

- Fires when late cancels + no-shows reach 40% of bookings over the last 6 weeks, minimum 4 bookings.
- Earlier than absence, and specific enough to act on.

### 3. First thirty days

A member's first month predicts lifetime value better than any later window, and it is the most rescuable period.

- Fires when a member has been joined 14–35 days and has fewer than 3 attended visits.
- Distinct from `new_member_stalled` in Business Rules §11, which is an insight; this is the band behind it.

### 4. Payment state

- Membership `past_due`, or a class pack expired within 30 days with no replacement purchased.
- Factual rather than predictive, but it is a live reason a member cannot book.

### 5. Membership expiry with declining usage

The renewal decision is made before the renewal date.

- Fires when a membership renews within 21 days **and** usage in the current period is below 60% of the member's own prior-period usage.
- Either condition alone is not a signal. Together they are the moment someone decides not to renew.

---

## Deliberately excluded

**Challenge and streak participation.** It correlates with engagement but is noisy: many loyal members ignore gamification entirely. Scoring them down for it produces false alarms in exactly the population the owner least wants to be nudged about. Revisit only if the data shows non-participants actually churn more.

**Studio-average comparison anywhere.** A twice-weekly member and a fortnightly member are both healthy. Comparing either to a studio mean manufactures problems that do not exist.

**Demographics, tenure alone, spend.** A member who has been there three years and comes weekly is healthy. A high spender who stopped coming is at risk. Neither fact adds anything the behavioural signals do not already carry.

---

## Band assignment

| Band | Condition |
|---|---|
| `at_risk` | Signal 1 at ≥3× baseline, or signal 4, or two or more signals firing |
| `drifting` | Any single signal firing |
| `healthy` | No signal firing |
| `new` | Joined under 14 days — the signals do not apply yet (amendment below) |

A member with fewer than 6 visits and joined more than 35 days ago has **no band**, not a healthy one. Absence of evidence is not evidence of health, and a falsely reassuring band is worse than none. Show `insufficient_history`.

### Amendment — the `new` band

A member joined fewer than 14 days ago is `new`, whatever their visit count. The reason states where they are: "Joined 5 days ago, no visits yet" or "Joined 5 days ago, 2 visits".

This closes a hole in the bands above. Signal 3 starts at day 14 and `insufficient_history` needs more than 35 days, so days 0–13 fell through to `healthy` — and "healthy, no visits" is the most rescuable member a studio has, described as though nothing is wrong. The first fortnight is not a period where the signals return a clean result; it is a period where they do not apply, and the band should say so rather than defaulting to reassurance.

`new` is **not a warning**. It is a distinct state meaning the signals have not had enough time to mean anything. An owner scanning the list should read it as "too early to tell, here is where they are", and the reason gives them the one fact worth acting on — whether the member has actually been in yet.

At day 14, signal 3 takes over exactly as specified: joined 14–35 days with fewer than 3 attended visits fires `first_month_stalled`.

Because `new` means the signals do not apply, it is decided **before** them, and a member in their first fortnight is `new` even if another signal would otherwise fire.

---

## Reasons are member-level, never categorical

The reason string must name the member's actual behaviour.

- Wrong: "Retention risk — low engagement."
- Right: "Was coming twice a week through July, last visit 16 days ago."
- Wrong: "Booking behaviour concern."
- Right: "Booked 6 classes in the last month, attended 2."

The owner knows their members. Give them the fact they missed, not a label they have to decode.

---

## Computation and storage

Computed nightly per studio, and on check-in for the member checking in, so a returning member's band updates before they leave the building.

Stored on `members` as a cache (band, reason, computed_at, signals fired). Derived from `check_ins`, `bookings`, `memberships` and `credit_ledger` — never edited in place, always recomputable. If cache and source disagree, source wins, per the derived-values table in the data model.

The score feeds `ai_insights.type = 'retention_risk'` and the Morning Brief. Business Rules §11's insight threshold and this band are the same underlying calculation; §11 governs when an insight is *raised*, this decision governs what the band *is*.

---

## Status

Settled. Blocks the Health Score implementation and the Morning Brief.

**Where:** Data Model §5 (members cache), Business Rules §11, migration 018. **Status:** settled.

---

## Screen inventory

| Surface | Count |
|---|---|
| Staff app | 49 |
| Member PWA | 22 |
| Account / onboarding | 9 |
| **Total** | **80** |

Instructor surface is five screens: My Schedule, Class Roster, Member Quick View, My Availability, My Stats. Was three before Decisions 9 and 10.

---

## Open — not decided

1. **Instructor-initiated cancellation and substitution requests.** Currently Owner/Manager-initiated only. Adding this means a sixth instructor screen, a request state machine, and an approval queue on the admin side. Decision 2 governs what members are owed when a substitution lands late; this is about who initiates.
2. **Reschedule inside the cancellation window.** Reschedule is cancel plus rebook and inherits the window. Open question is whether a same-week move to another occurrence is treated more leniently than a plain cancel. Affects credit consumption and seat release.
3. **POS.** Verify against Chapter 8 whether in-person retail is actually in V1. Module 3 covers plans, packs, credits, promo codes and gift cards. Physical retail adds inventory, which is a different system.
4. **Single tier vs plan gating.** Recommendation on record: V1 ships as one product at one price. Ten design partners with unannounced pricing don't need plan-gating logic, and building it now means guessing which features studios refuse to live without before any studio has used the product.
5. **Stripe onboarding time-to-complete.** Connect Standard OAuth requires the studio to have or create a Stripe account during setup. Time it with a design partner against the one-hour target.
6. **Member identity across studios.** Same email can be a member of two studios; separate accounts per subdomain, no policy joins them. Confirm this is acceptable.
7. **Archived-member retention.** How long before GDPR hard delete, and who can trigger it.
8. **Front-desk refunds.** Currently denied. Revisit if design partners find it too restrictive.
9. **Instructor challenge credit on substitution.** Currently credits whoever actually taught the class, not the originally scheduled instructor. Fair reading, but it means an instructor who picks up subs climbs faster than one teaching a steady timetable.

---

## Excluded from V1 — Chapter 7

Raised in brainstorming, confirmed out:

| Item | Reason |
|---|---|
| Automate membership continuity promotions | Marketing Automation |
| Share milestones to social | Community-adjacent |
| Refer friends | Referral engine, not in the seven modules |
| Instructor incentive/payroll tracking | Wave 3 (Decision 10) |
| Multi-location | Ch. 7, though schema is ready (Decision 8) |
| API access | Ch. 7 |
| Community feed | **Conflicts with the Bible.** Ch. 10 puts a feed, reactions, announcements and friend connections in launch scope. Excluded here to fit six months. Needs an explicit call. |


---

## 15 — A `lead` may book, but only as a drop-in

Business Rules §2.1 rule 5 is "member status is `active`". A `lead` — someone who has signed up on the studio's subdomain and has never bought anything — fails it and cannot book at all.

That is the wrong answer for the best new member a studio gets: a walk-in who finds the studio on their phone on Tuesday evening and wants tomorrow's 7am. Making them wait for a staff member to flip a flag loses the booking, and it loses it at the exact moment their intent is highest.

**Rule 5 now passes for `status in ('active', 'lead')`.** `inactive` and `archived` continue to fail, unchanged.

Because rule 5 is evaluated *before* §2.2 resolves who pays, a second guard runs after resolution: **if the member is a `lead` and the resolved payment source is anything other than `drop_in`, the booking is refused** with `member_not_active`. A lead has by definition bought nothing, so in practice they always resolve to drop-in; the guard exists for the case where staff attach a membership to somebody without activating them, and it means "lead" can never quietly become a way to consume credits that were never sold.

Attending as a drop-in does not itself promote a lead to `active`. Status is a thing staff set when they sell something, and a booking that is never paid for at the desk should not leave a `lead` looking like a member.

**Where:** Business Rules §2.1 rule 5, §2.2; migration 027. **Status:** settled.

---

## 16 — Studiior is a booking platform, not a payment processor

Payments were built Stripe-first: migration 038 made Connect the way a membership gets sold, and a studio without a connected account could not take money through the product at all.

That is the wrong foundation. **A studio records payments however it already takes money** — cash, bank transfer, GCash, a card terminal on the counter, anything. Online card payment through a connected provider is an **optional adapter on top of that**, not the thing everything else is built on.

**Why.** The design partners span countries where provider coverage varies, and Stripe does not support the Philippines at all. Requiring a provider would exclude studios whose only problem is booking — which is the problem we actually solve. It is also precisely the rigidity we position against: Mindbody makes you do it their way, and a studio that already has a working way of taking money should not have to change banks to get a schedule.

**What this means concretely.** `payments` carries a `provider` — `manual` or `stripe` — so revenue reporting can tell them apart and a studio can reconcile. A manual payment activates a membership, grants a pack and confirms a drop-in through *the same functions* a Stripe payment does; there is one path, not two that drift. Refunds and adjustments work the same way for both. The Stripe work stays exactly as built, as the first adapter.

**The tradeoff, recorded rather than hidden.** A manual payment is the studio's own bookkeeping: they reconcile it themselves, and a membership can be marked paid when no money actually moved. Nothing in the product prevents that and nothing should try to. It is the studio's business, and a booking platform that polices its customers' cash handling has misunderstood what it is for. What we owe them is that the record says who recorded it, when, by what method and against what reference — enough to reconcile, not enough to police.

**Where:** Business Rules §7.1; data model §7; migrations 040 and 041. **Status:** settled.

---

## 17 — Instructors can apply for open shifts, superseding part of Decision 9

Decision 9 said instructors submit availability and never touch the timetable. That was right about **assignment** and wrong about **asking**.

**What Decision 9 keeps, unchanged.** An instructor never assigns themselves. They cannot create, move, cancel or reschedule a class. Approval is always staff — owner or manager. Assigning outside stated availability remains permitted with a warning, never blocked.

**What is new.** A class can be published **unassigned**, as an open shift. Instructors see the open shifts and apply for them; staff approve or decline. This is what studios running on freelance instructors actually need, and without it every shift has to be filled by a manager chasing people individually.

`class_occurrences` carries a staffing state — `assigned`, `open`, `pending_approval` — which is explicit rather than inferred from a null `instructor_id`, because "nobody is teaching this" and "we have not got round to it" are different problems and were previously the same value.

**The edges.**

- **Several people apply for one shift.** Every application stands until staff approve one. Approving auto-declines the rest *in the same transaction*, so there is no window in which two instructors both believe they have it, and each of the declined is told.
- **An approved instructor withdraws.** The class returns to `open`, staff are notified, and it is loud — the notification carries how many members are booked, because "nobody is teaching this" and "nobody is teaching this and eleven people are coming" are different emergencies. This is the worst state the system can be in and the product should behave like it. **Superseded by Decision 18:** withdrawing now raises a cover request and the instructor stays on the class until staff answer. The loudness and the booked count survive; the automatic release does not.
- **Applying outside stated availability.** Permitted, and the warning travels with the application so the person deciding sees it at the moment they decide. Same reasoning as Decision 9's assignment rule.
- **An open shift with members booked and no instructor.** Raised in the Morning Brief as `unstaffed_class`, ranked above every other insight including a failed payment: a declined card can be sorted out on Thursday, and a 7am class tomorrow cannot. §11 had no type for this.
- **An open shift still holds its room and its slot.** It has a time, a capacity and possibly members booked; only the person is missing. The room exclusion constraint applies regardless of staffing.

**Also settled here, because the calendar forced it:** room and instructor double-booking are now database exclusion constraints rather than nothing at all. `createClass` had never checked either. Moving a class with members booked emails them (`class_moved`, not opt-outable) — cancelling and rebooking would have been the alternative and is wrong in the data.

**Where:** Business Rules §5; Data Model §5; Permissions §4 and §6; migrations 047, 048 and 049. **Status:** settled. **Supersedes:** Decision 9's implication that instructors have no route to the timetable at all.

**Amendments to 17, settled during the build.**

- **Substitution needs no carve-out.** `substitute_for` records history; `instructor_id` is the effective teaching instructor, so a class being subbed already stops counting against the original. What was actually blocked was a *swap* of two instructors between two simultaneous classes — a valid end state refused on the way there. The instructor constraint is now `DEFERRABLE INITIALLY IMMEDIATE`, which tolerates the intermediate state and still refuses to commit a double-booking. Rooms remain immediate and have the same swap friction.
- **A significant move owes a free cancellation** — further than `studio_settings.significant_move_hours` (default 2) or onto a different day in studio time. Same reasoning as Decision 2: the member agreed to a time and the studio changed it.
- **An unstaffed class has a deadline**, `studio_settings.unstaffed_deadline_hours` (default 48). Past it with nobody assigned, the Morning Brief raises it, and the calendar shows it hatched in coral rather than merely a different colour.
- **Members are not told a class is unstaffed.** They see a normal class and the instructor's name once there is one. Advertising the uncertainty invites them not to book, and the class is what they came for.

---

## 18 — Availability is a standing pattern, and cover is always granted by staff

Extends Decisions 9 and 17. Neither is overturned.

**Context, which is what makes this different from Decision 9's version of availability.** The studio's instructors are on a fixed recurring weekly schedule with a minimum three-month commitment: 9–12 classes a week, consecutive 50-minute slots, planned absences given in advance, and a willingness to cover for each other. Availability under that model is not a thing an instructor re-enters every Sunday. It is a **standing pattern with a start and an end date**, entered once by the studio when the commitment begins, and amended by exception.

`instructor_availability` has carried `day_of_week`, `starts_at_time`, `ends_at_time`, `effective_from`, `effective_to` and `exception_date` since migration 001, and `instructor_available_at()` has read all of them since 047. **The schema was never the gap — the editor was.** No screen in the product could write a single row of it, which is why every warning that function produces has been computed against an empty table.

### The editor is per instructor and entered in one go

A row per weekday, Sunday to Saturday; several time ranges per day; a day with no ranges reads "Unavailable". **Copy-a-day-to-other-days is the control that makes the feature usable** — 9–12 consecutive classes a week means most days are the same two ranges, and entering them seven times by hand is how a studio decides not to bother.

**The whole week is written as one replacement, not row by row.** `set_instructor_availability()` takes the entire pattern and swaps it inside one transaction. Editing a weekly pattern by INSERT and DELETE per range means a half-applied week is reachable — and a half-applied week silently changes who `instructor_available_at()` says can teach. Copy-to-days is therefore a client-side operation on the form, and what reaches the database is always a complete week.

Dated exceptions are a separate list and a separate call, because they are a different act: the pattern is the commitment, an exception is a Tuesday in September.

**Manager-up writes it, the instructor writes their own, and both write the same rows** — `availability_manager_all` and `availability_self` already say so. Decision 9's rule that assignment outside stated availability is permitted with a warning is untouched.

### The instructor submits the month; the studio approves it

**Extended in migrations 066 and 067.** Decision 18 built the editor and gave it to the studio. The instructor now gets the same editor for the month ahead, behind an approval step, because a pattern that decides who the engine will schedule must not change because somebody typed it about themselves.

**Draft, submitted, approved, changes requested.** Approval is manager-up. A review that sends a pattern back must carry a reason — "changes requested" with no note is a refusal wearing a softer word. Staff can still enter a pattern directly, exactly as before: an instructor who sends their hours by message must not be blocked by a workflow.

**Everything that existed on the day this shipped was already approved.** Every `instructor_availability` row was entered by staff, and **staff entry IS the approval**. `approval_status` therefore defaults to `'approved'`, so the migration invalidated nothing, and a manager submitting on somebody's behalf lands approved for the same reason.

**A submitted month wins for its own days.** It does not replace the standing pattern and does not merge with it — either would silently rewrite what a studio entered. `instructor_available_at()` resolves: dated exception, then approved submission covering that day, then the standing weekly pattern, then "nothing stated at all, which means available". **A pattern awaiting approval counts as nothing**, including for the "has this person stated anything" test.

**The monthly cycle is a per-studio setting.** Patterns for month M are due on `studio_settings.availability_due_day` of the month before, default the 20th. The reminder, the due date and the "who hasn't submitted" list all read that one column. Instructors with no login cannot be reminded and are listed for the studio to chase by hand.

**Commitments gate none of it.** An instructor who offers fewer hours than they agreed to is still approved if staff approve it. The shortfall is a conversation, and `commitment_report()` is where it is had.

### The week is confirmed in one action

**Migration 067.** "Confirm all 11 classes", with the list visible above it, and per-class "ask for cover" beside each — which raises the cover flow above rather than inventing a second one. A class somebody has asked cover for is **answered, not unconfirmed**: chasing them about a class they have already said they cannot teach is the opposite of the point.

**The timing is the feature, and every part of it is a per-studio column.** Ask on Thursday for the week ahead (`week_confirm_ask_dow`). Remind once on Saturday, only if something is unanswered (`week_confirm_remind_dow`). Escalate on Sunday (`week_confirm_escalate_dow`) and **only for classes inside the next three days** (`week_confirm_escalate_days`) — a Friday class unconfirmed on Sunday is not yet a problem, and reporting it as one is how a studio learns to ignore the alarm. Confirming after the reminder clears everything silently; there is no "you were late" state.

**Staff get one line, not eleven alarms.** "3 instructors haven't confirmed this week", with who and which classes, composed once in `unconfirmed_summary()` so the email and the screen cannot phrase it differently. The escalation is one email per studio per day.

**An unconfirmed class is NOT automatically an open shift.** Nothing here touches `staffing` or `instructor_id`. It is flagged for staff, who decide. Auto-opening a class because somebody was on holiday and missed a button would be a worse failure than the one it solves.

### The commitment MEASURES instructors; it does not schedule them

New table `instructor_commitments`: instructor, start and end date, minimum and target classes per week, shift preference, status.

**This is the distinction, and it is absolute.** The commitment is a **hiring expectation** — what was agreed when somebody was taken on — and a **performance measure**: what they actually taught, against that agreement, over its term. It is **never a scheduling input.** It must not affect booking, assignment eligibility, the availability validity window, or anything a member sees.

**Amended, because the first implementation got this wrong in two places.** Migration 061 ranked assignment candidates by deficit against `target_per_week`, and 061 also defaulted a blank `effective_from` / `effective_to` from the live commitment "so the pattern and the agreement cannot drift apart". Both are removed in migration 065.

The ranking was wrong because *"furthest below their target" is a true number with a false meaning.* A studio running 35 classes a week across six instructors cannot give anybody twelve, so that phrase would have appeared on every line of every run summary, describing a gap the studio has no way to close and the engine no business trying to. Distribution is by **fewest classes assigned that week, full stop** — which is what the no-commitment fallback already did, so the fix deleted a branch rather than adding one. `commitment_fallback` and `no_commitment_for` go with it: with no other behaviour to fall back *from*, there is nothing to report.

The defaulting was wrong because the validity window is a **hard gate** — the engine, the cover board's candidate list and `move_occurrence()` all refuse outside it. Filling it from the agreement meant a commitment reaching its end date silently made somebody unschedulable: the agreement deciding the roster by a back door. A blank window is now open-ended.

**What the commitment IS for is reporting.** `commitment_report()` (migration 065) gives, per instructor over the commitment's own period: actual classes per week against the agreed minimum, weeks under and weeks at or over, the average, the trend of the recent weeks against the earlier ones, and a standing. It counts through `instructor_weekly_load()`, the same function the brief insight uses, so the two cannot disagree about what a week contained. Complete weeks only — the current week is a number still going up, and putting it in a performance measure makes everybody look short every Monday. This feeds the scorecard and any bonus conversation.

**Standing is measured against the MINIMUM, not the target.** The target is recorded and reported and is deliberately not a pass mark, for the same reason it is not a ranking input: a studio with fewer classes than its roster needs cannot hand anybody their target, and should not be told its whole roster is failing.

**An instructor persistently under their weekly minimum reaches the Morning Brief.** `commitment_shortfall` stays exactly as it is — a three-month commitment that quietly ran at six classes a week instead of nine is a conversation that has to happen in week three, not in month three when it is a grievance. "Persistently" is a studio threshold, not a single bad week — one week under is a holiday and everybody knows it. It is a **management signal, never a scheduling input**, and that sentence is the whole of this section restated.

This is a performance record, not a compensation one. Decision 10 keeps anything that resolves to money owed out of V1, and counting classes against a commitment does not cross that line: nothing here computes a rate or a total.

### Cover is requested, never taken

An instructor who cannot teach a class requests cover. **Staff always approve. There is no self-release at any notice, however urgent** — that is Decision 9's rule about the timetable, and urgency is exactly when it matters most.

**Requesting cover does not change who is teaching.** Until staff act, the original instructor is still assigned and the class is still staffed. A cover request is a row in its own table and touches `class_occurrences` not at all.

The database backs this up, though **not in the way it first appears**. `occ_staffing_matches_instructor` from migration 047 forbids the pair, but the constraint never fires: `tg_derive_staffing()` from the same migration runs first and *silently rewrites* `staffing` to agree with `instructor_id`. So `update class_occurrences set staffing = 'open'` on an assigned class does not error — it succeeds, and leaves the row `assigned`. The state Decision 18 depends on is genuinely unreachable, but the mechanism is coercion rather than refusal, and the difference matters to anyone reading the constraint and concluding a stray write would be caught. It would not be caught. It would be corrected, quietly, and the only way to release a class is to clear the instructor deliberately.

**This overturns one edge of Decision 17 rather than extending it, and the two cannot both stand.** Decision 17 said an approved instructor who withdraws returns the class to `open`, loudly — and `withdraw_from_shift()` implemented exactly that: unconditional self-release, clearing `instructor_id` with nobody's approval. A rule saying "no self-release, however urgent" with a button next to it that releases the class is decorative. Withdrawing from an assigned class therefore now **raises a cover request**: the studio still hears immediately and still gets the booked count, and a person decides. `scheduling_test.sql` asserted the old behaviour and now asserts its inverse, because what it used to prove is precisely what must no longer happen.

Withdrawing a **pending application** is untouched. Nobody is counting on you before you have been approved, and taking your name off a list you put it on is not releasing a class.

On approval staff choose one of two things, and both are Decision 17's machinery rather than a new system:

- **Assign someone directly** — `move_occurrence()` with a new instructor, which is already the only thing that moves a class and already carries the exclusion constraints and the availability warning.
- **Publish it as an open shift** — clear the instructor, `staffing = 'open'`, and it appears in the shifts list for instructors to apply for. From there it is `apply_for_shift` and `approve_shift_application`, unchanged.

**Approval is the risk, because approval is required.** A request nobody sees is a class nobody teaches. So: every owner and manager is notified the moment it arrives; it sits at the top of the staff app until it is answered; and **if the class starts within `cover_escalation_hours` and the request is still unanswered, it escalates** — the notification repeats, the banner changes its language, and it becomes the loudest item in the Morning Brief, ranked above the unstaffed class that Decision 17 put above a failed card. An unanswered cover request four hours out is the same emergency as an unstaffed class, arriving earlier and still fixable.

**What members are told is Decision 2, unchanged.** A substitution announced after the cancellation cutoff has passed grants a penalty-free cancellation under `sub_late_free_cancel`. Decision 18 does not restate that rule; it finally *calls* it — `queue_substitution()` has existed since migration 030 with no caller, so changing a class's instructor has until now told the booked members nothing at all.

### Being given a class is itself news

**An instructor assigned to a class is told.** Nothing in the product did this: `move_occurrence()` wrote an audit log and sent no one anything, and an instructor found out by looking. Assignment, cover requested, cover approved, cover declined, and cover picked up by somebody else all queue through the existing `queue_` functions.

**Push is not built and this decision does not pretend otherwise.** `push_subscriptions` has existed since migration 001 with nothing writing it, there is no service worker subscription, no VAPID keys and no transport — and `send_due_notifications()` claims every scheduled row regardless of channel, so a queued push row would be posted to Resend and delivered as an email. The worker is now scoped to `channel = 'email'` so that cannot happen. Escalation is therefore email plus two in-app surfaces that a working studio cannot miss. **Gap, stated rather than implied:** same-day cover on a phone that is not open wants push, and push needs a subscription table write path, a service worker and a second `send_via_*`.

**Reading someone's availability is a permission, not a convenience.** The three functions that read it are `SECURITY DEFINER`, so the grant to `authenticated` is the whole of their access control unless they check for themselves — and they did not. An ordinary member of an unrelated studio could read any instructor's full weekly pattern by id while the table's own policy correctly returned nothing. Migration 056 applies the write path's rule to the reads: manager-up of that instructor's studio, or the instructor themselves. An id that does not exist is refused identically, so the error cannot be used to enumerate instructors.

**Where:** Business Rules §3.3 and §5; Data Model §5; Permissions §4 and §6; migrations 053, 054, 055 and 056. **Status:** settled. **Extends:** Decisions 9 and 17. **Reuses:** Decision 2 for members, Decision 17 for open shifts.


---

## 21 — Flex classes

**Optional per studio, off by default, and invisible to members.**

A class is **guaranteed** — it runs regardless of headcount, which is every class in the product today — or **flex**: it runs only if it reaches a minimum by a deadline, and otherwise cancels. A studio that never turns it on sees no change anywhere, and no member sees anything either way.

**Reform Collective's Phase 2** runs flex slots beside core ones so the coach is already on site. Threshold 1, deadline 20:00 the night before. One booking runs as a semi-private at no extra charge.

### Configured per SERIES

Not per class type and not per time band: Phase 2 has a 07:00 flex slot beside an 08:00 core one on the same days, and SCULPT appears in both. Neither alternative can express that; the series is the thing that knows.

`class_series.flex` and `minimum_bookings`, inherited by the occurrences the generator makes. **The minimum is an integer, not a boolean** — a studio with twelve reformers may want three, Reform Collective wants one.

The deadline is per studio, in two shapes: a fixed local time the night before (Reform Collective's), or a number of hours ahead. Both are studio-local, and the night-before form is computed from the class's **local date** rather than by subtracting an interval, which would drift an hour across a clock change.

**Staff can flip a single occurrence to guaranteed.** "This one runs whatever happens" is a real decision on a quiet week, and the sweep then leaves it alone.

### Members see nothing

No "unconfirmed", no "needs one more". Telling somebody a class might not run is telling them not to bother booking it, which is the opposite of what a class one short needs. `flex` lives on `class_occurrences`, which the member app selects by name — the column is simply never asked for.

If it cancels, **Business Rules §3.2 applies**: credits back regardless of timing, fees waived, everybody booked told. At threshold 1 with nobody booked there is nobody to tell, which is the common case.

### The deadline

A pg_cron sweep every fifteen minutes, per studio, in studio-local time. Fifteen and not sixty for the same reason as the Morning Brief: the deadline is a local time and studios span zones, and a coach finding out at 20:59 whether to come in tomorrow is what this exists to prevent.

**Idempotency is the occurrence's own state, not the `job_runs` claim.** A decided class is confirmed or cancelled and is never pending again. That matters because the hours-before mode has a decision point at every hour of the day, and a once-a-day claim would answer only the first of them; `job_runs` records the pass and counts attempts rather than gating it.

- Confirming is **silent** — nothing changes from the member's view, because nothing about the class was ever different.
- Cancelling goes through `cancel_occurrence()`, the §3.2 path.
- **The instructor is told either way.** A coach needs to know whether to come in, and that is the whole point of a deadline.
- **Once confirmed it runs.** `flex_confirmed_at` is a latch: a cancellation afterwards drops the headcount below the minimum and changes nothing.

### Reporting

`flex_report()` gives flex fill against core fill, per series. **Fill is measured on the classes that RAN** — a cancelled class has no fill rate, and averaging its zero in would make flex look emptier than it is and argue against the very slots that are working. A flex slot filling as well as the core one beside it has earned core status; that is the number this is for.
