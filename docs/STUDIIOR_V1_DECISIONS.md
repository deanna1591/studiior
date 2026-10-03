# STUDIIOR V1 — DECISION LOG

**Canonical.** Every entry here is settled. If code contradicts this file, the code is wrong. If you think an entry is wrong, change it here first with a reason, then change the code.

**Source of truth above this file:** `docs/STUDIIOR_PRODUCT_BIBLE.md`. Note its per-chapter **MVP Scope** sections — Ch. 4, Ch. 5, 6.23, Ch. 7, 8.18, Ch. 10, Ch. 12 — which is where scope actually lives. The earlier citation here ("Ch. 8 seven modules, Ch. 7 exclusions, Ch. 9 roles, Ch. 20 scope test") pointed at chapters that either say something else or do not exist; roles are in `STUDIIOR_V1_PERMISSIONS.md`.

**On the numbering:** the entries are not contiguous. **13** is real — the community-feed exclusion — but it lives in *Excluded from V1* below rather than as its own `## 13`. **19** and **20** were never assigned; checked against git history (`git log -S "Decision 19" --all` and 20 return nothing, no doc references), they are skipped numbers, not lost entries. Recent decisions (25–30) sit just below Decision 18, newest first.

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

> **AMENDED BY DECISION 22.** The paragraph above is no longer true, and it is left standing rather than rewritten so the change is visible. Per-class rates, bonus thresholds and a period statement are now IN V1. Decision 22 explains why: guarantee tiers create an obligation the studio owes whether or not the class runs, and an obligation nobody computes is one that gets settled from memory. **Everything else in Decision 10 stands unchanged** — recognition is still not compensation, My Stats is still descriptive, and a public staff leaderboard is still a studio setting, default off. Payout is still out: Studiior computes what is owed and never moves the money.

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

### Amendment — drop_in and trial activate as packs, never unlimited (Deanna, 2 Oct 2026)

A drop_in plan activates as a pack of exactly ONE credit; a trial plan activates as a pack of `plan.credits` (default 1) — both through the `credit_ledger` like a class pack, with `validity_days` (default 30 when null) setting `expires_on`. Neither is ever unlimited. The member app shows "1 class · use by {date}", never "Unlimited classes", for these types. `max_bookings_per_day` on any plan is enforced by `book_class` as today.

**Why.** `activate_purchase` set `credits_remaining = (case type when 'class_pack' then plan.credits else plan.credits_per_period end)`. For a drop_in or trial, `credits_per_period` is NULL (the `plan_credits_per_period_recurring_only` CHECK forces it), and Decision 12 above makes a NULL `credits_per_period` mean **unlimited** — so a ₱100 one-class drop-in activated as unlimited, with no ledger rows and no expiry. Reproduced on hosted (Reform): a member on a `Test Payment` drop_in showed `credits_remaining = NULL`. The unlimited semantics belong only to a **recurring** plan with a null allowance; a pack-shaped plan (class_pack, drop_in, trial) is always a finite bundle reaching booking through `credits_remaining` and the ledger.

**Where:** migration 201+ (re-issue `activate_purchase`), the member-app plan/Home cards and `member_bootstrap` (an "unlimited" reading must be recurring-only), the plan form (drop_in locks credits to 1, trial defaults credits to 1). **Status:** settled. **Amends:** this Decision (12). **Reuses:** the class-pack `credit_ledger` path, `book_class`'s existing `credits_remaining` consumption and `max_bookings_per_day`.

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
| Instructor incentive/payroll tracking | **In V1 as of Decision 22.** Per-class rates, guarantee tiers, a conversion bonus and a period statement. Payout itself stays out — Studiior computes what is owed and never moves the money. |
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

## 56 — The dashboard shows recent bookings and cancellations, and suggests core/flex tier changes from real demand

**Decision.** Two additions to the owner's dashboard, both read-only views over data that already exists. (1) **Recent bookings.** A "Recent bookings" block lists the newest bookings and cancellations across the studio — "{Member} booked {Class} · {day} {time}", "{Member} cancelled {Class} · {day} {time}" (late cancellations say "cancelled late"; a staff-side class cancellation that released seats says "{Class} · {day} {time} was cancelled — N members notified"). Free-first provisional seats read "booked a free class". Newest first, 10 rows, "Show more" to 30. Visible to desk-up (bookings are desk work), no amounts anywhere in it. The existing "Everything happening" feed is unchanged (it deliberately excludes bookings). (2) **Tier suggestions.** When guarantees or flex are enabled, the dashboard shows a "Tier suggestions" block and the Series page gets the same list: for each active recurring class with at least 4 completed occurrences in the last 28 studio-local days, compare the booked count at class start (confirmed seats only — provisional free-first seats and waitlist excluded) against the studio's minimums. A **core** class whose booked count was below `core_min_bookings` in 3 or more of its last 4 completed classes → "Consider making {Class} flex — N of the last 4 classes had fewer than {core_min} booked (avg X)". A **flex** class whose booked count met `core_min_bookings` in all of its last 4 → "Consider making {Class} core — all of the last 4 met the core minimum (avg X)". Each row links to the series page where the owner changes the tier themselves; **nothing changes automatically, ever, and no email is sent.** Manager-up only (tier is a pay decision, Decision 22). Classes with fewer than 4 completed occurrences in the window show nothing ("Not enough classes yet to suggest tier changes." when the whole list is empty for that reason; the block is hidden entirely when both guarantees and flex are off). Suggestions are computed on read; nothing is stored; no AI call is made — the rule above IS the suggestion.

**Why.** The owner asked to see what members are doing as it happens, and to be told when a class's tier no longer matches its demand. The booking feed makes the member app's activity visible at the desk. The tier rule is the instructor-pay logic (Decision 22: core minimum guarantees a fee whether or not members come) read backwards: a core class that keeps missing its minimum costs the studio a guarantee it is not earning; a flex class that always clears the minimum is under-paying the instructor relative to a core class. A plain rule the owner can verify beats an opinion.

**Where.** Migration 211: `dashboard_recent_bookings(studio, limit)` (desk-up) and `tier_suggestions(studio)` (manager-up), both readers, both `stable`. `components/dashboard/recent-bookings.tsx`, `components/dashboard/tier-suggestions.tsx`, `lib/dashboard.ts`, `app/staff/page.tsx`, the Series page. **Status:** settled. **Reuses:** Decision 22 (core minimum), Decision 21 (flex), Decision 30 amendment (`bookings.provisional`), Decision 55 (`fmt_clock`), Decision 47 (`no_instructor` / staff cancellations). **Inert by default:** a studio with guarantees and flex both off never sees the suggestions block. Deanna, 3 Oct 2026.

---

## 55 — Per-tenant 12-hour time format, and the free-class picker on the day strip

(1) A studio chooses how times are shown: 24-hour (13:00) or 12-hour (1:00 PM). `studio_settings.time_format text not null default '24h' check in ('24h','12h')` — default keeps today's behaviour product-wide; Reform Collective uses 12h. One formatter honours it everywhere a member, instructor or staff user sees a clock time: member app, instructor portal, staff app, notification emails and .ics descriptions (never the .ics DTSTART itself), the website embed (`public_schedule` exposes the setting), the Install and login pages. Dates are unaffected. (2) The free-first-class picker (Decision 30 amendment) uses the same day strip as regular booking: the member picks a day and scrolls, sees only the classes they can book free, each with 'Book free' and a '{n} going' chip, chronological within the day; the strip opens on the first day with an eligible class and marks days that have one. The long flat list is removed. Deanna, 2 Oct 2026.

**Mechanism — the setting.** `studio_settings.time_format` (default `'24h'`, CHECK in `('24h','12h')`). Set in **Settings → Branding** (not Timetable): it is a presentation choice about what members see — the same screen that carries the accent, theme preset, login tagline and the public instructor-name rule (Decision 51), all "how it looks to members". Exposed through `studio_by_slug` (the pre-login login / install pages), `member_bootstrap`, the staff ctx (`staff_bootstrap`), the instructor ctx, and `public_schedule` (as `time_format`) — **no new anon surface, still exactly twelve**.

**Mechanism — one formatter, two sides.** TypeScript: `lib/time.ts` gains `fmtClock(value, tz, format)` (a Date or minutes-of-day → `"13:00"` or `"1:00 PM"`), and every existing clock-time rendering routes through it — the member app, the instructor portal, the staff schedule, the embed (which reads `time_format` from `public_schedule`). SQL: one helper `fmt_clock(ts, tz, format)` replaces every member/instructor-facing `to_char(..., 'HH24:MI')` in a notification payload or digest (`when`, `deadline_short`/`deadline_long`, `{time}`, `cutoff_long`, `cancel_deadline`, the instructor week/tomorrow digests), each sender re-issued from its newest definition and passing the studio's `time_format`. **Dates and day names are unchanged; the `.ics` `DTSTART`/`DTEND` stay the machine `HH24` UTC format** — only the human description text a person reads is reformatted. Midnight is `12:00 AM`, noon `12:00 PM` under 12h.

**Mechanism — the free picker.** The Decision 30 amendment's flat `free_first_class_list` list in `app/member/book` is replaced by the regular-booking day-strip layout, fed by the same `free_first_class_list` grouped by studio-local day and chronological within the day. Each row: the time (per the setting), class name, instructor, room, a `{n} going` chip (headcount including provisional seats), and 'Book free'; a cap-full class is shown muted as 'Full for free classes' and is unbookable. The strip marks (a dot) every day with at least one eligible class and opens on the first such day; a day with none shows "No free-class slots this day — try another day." The header stays "Your free class — pick one." with the sub-line "Days with people already in are a good bet." Once the member's free class is used the picker disappears, as today (they are no longer eligible).

**Where:** migration (time_format + `fmt_clock` + the re-issued senders + the exposers); `lib/time.ts` `fmtClock`; `app/member/book` free picker. **Status:** settled. **Reuses:** Decision 30 amendment (the free-class eligibility + provisional machinery), Decision 51 (the Branding "how members see it" group). **Off by default** (`'24h'` = today), asserted inert by the `all_off` canary.

---

## 54 — Instructor portal polish (owner's first walkthrough), install-page tightening, and two Decision 55 follow-ups

Instructor-portal copy and signals, from the owner's first walkthrough: (1) the portal speaks in weeks, never 'fortnight' — My schedule shows this week with Earlier/Later paging by week, and empty states say 'Nothing on this week'; (2) every class an instructor sees carries a small core/flex tag, and a flex class shows when it is decided ('flex · decided by 8:00 PM Mon') — instructors never see headcount-to-minimum wording ('needs 3 more'), and members and the website never see the tag at all (Decision 21); (3) the open-shift tab and screen are called 'Open classes', with 'Take this class' as the action, never 'Claim'; (4) the manual Fill tool offers the Decision 38 'already confirmed with the instructor' tick like the Assign panel, default ticked; (5) the Home empty-state link reads 'See what's on'; (6) the Install page shows the QR code only on desktop, shows only the viewer's own platform's steps with the real icons drawn inline, and warns about in-app browsers. Deanna, 2 Oct 2026.

**Mechanism — weeks, not fortnights.** The instructor portal already pages `instructor_week` by a `(from, to)` window; My schedule now defaults to the current studio-local week (`studio_week_start`), Earlier/Later move one week, "This week" returns. Every 'fortnight' string is removed from the member/instructor tree and from instructor-facing notification templates. Empty state: *"Nothing on this week. Classes you're down to teach appear here as soon as the studio schedules them; open classes you can take are under Open classes."* The Home empty-state link reads **"See what's on"**.

**Mechanism — the core/flex tag (instructor-facing only).** Each instructor-facing class row (My schedule, Month, Open classes, roster header, cover offers) carries a small tag: **"core"**, or **"flex · decided by {deadline_short}"** read from `flex_deadline_for_run` (the service-role twin) through `fmt_clock`; after the decision it is **"flex · confirmed"** or the cancelled state. **Headcount-to-minimum wording is removed from instructor screens** — no "needs N more", no "still waiting on numbers"; the booked count (0/6) stays. **Members and `public_schedule` never gain a tier field** (Decision 21) — asserted by grep and by the `public_schedule_test` column assertion.

**Mechanism — Open classes.** The Decision 17 open-shift tab/screen is renamed **"Open classes"**, the action **"Take this class"**, the pending state **"You've asked for this class — the studio will confirm"**. Staff-side wording (the roster `open_shift`, `/shifts`) is unchanged — this is the instructor portal's vocabulary only.

**Mechanism — Fill tool confirmed tick.** The manual Fill tool (`assign_instructors`, "fill a month") gains the Decision 38 **"Already confirmed with the instructors — don't ask them"** tick, default ticked, exactly as the Schedule Assign panel (Decision 42a). `assign_instructors` gains `p_confirmed boolean default false`; when true it stamps `assignment_confirmed_by` and skips the Decision 38 ask (the same `mark_assignment_confirmed` path `assign_occurrences_for_period` uses), when false the existing per-instructor-per-day coalesced ask is queued.

**Mechanism — Install page.** QR shows **only on desktop** (no touch, wide viewport) — *"Scan to open this page on your phone"*; on a phone, no QR. iPhone vs Android is read from the UA and **only that platform's steps** render (the other folded under "Using a different phone?"), steps large and one per line with the **real icons drawn inline as SVG** (Share, add-to-home, ⋮, ⋯). An in-app-browser warning: *"If you opened this in Instagram or Facebook, tap ⋯ and 'Open in browser' first."* The Install button shows only on Android where `beforeinstallprompt` fires. Same on `/instructor/install`.

**Mechanism — free-picker rows (Decision 55 follow-up).** Each row in `components/member/free-class-list.tsx` is tappable and opens the class page (`/class/{id}`) like a regular booking row, with the same detail and the same eligibility sentences there; the row's inline **Book free** still books directly.

**Mechanism — finish the time format (Decision 55 follow-up).** The surfaces Decision 55 deferred are routed through `fmt_clock`/`fmtClock`: the cover/shift/waitlist/assignment email senders; the `guarantee_report`/`pay_statement`/`instructor_pay_summary`/`instructor_roster` labels; the staff roster, publish, shifts `when()`, timeline and dashboard activity; and the instructor Open-classes calendar (end time computed from the canonical `HH:MM`, formatted only for display). No member/instructor/staff-facing `HH24:MI` remains except the `.ics` machine fields — asserted by grep.

**Where:** a migration (re-issued senders/readers + `assign_instructors` `p_confirmed`); the instructor portal (`app/member/instructor/**`), `app/staff/schedule/fill/*`, `app/member/install/*` + `/instructor/install`, `components/member/free-class-list.tsx`, and the staff time-format surfaces. **Status:** settled. **Reuses:** Decision 55 (`fmt_clock`/`fmtClock`), Decision 38/42a (the confirmed-tick path), Decision 21 (members never see the tier), Decision 51 (the Install page). **Inert by default** where it touches the tag/flex (a studio with flex off sees only "core").

---

## 53 — Complimentary (house) studios on platform billing

A platform admin can mark a studio complimentary: it is never billed, never warned, never locked, and never enters past_due or trialing. For Studiior's own studio (Reform Collective) and any partner studio Studiior chooses to comp. New `platform_status` value `'complimentary'`. Set and cleared only from `/admin/billing` by a platform admin, with a note; clearing it starts a fresh 14-day trial from that moment, so a comped studio that is later charged gets the same runway as a new one. The Billing page for a complimentary studio shows "Complimentary — Studiior does not bill this studio." and no payment controls. Every sweep that warns, locks or charges skips complimentary studios. Deanna, 2 Oct 2026.

**Mechanism.** `platform_status` gains `'complimentary'` (its own migration step — a new enum value cannot be USED in the txn that adds it). `platform_subscriptions` gains `comp_note text`, `comp_set_by uuid`, `comp_set_at timestamptz`. `set_studio_complimentary(studio, note)` and `clear_studio_complimentary(studio)` — both `is_platform_admin`-guarded (PT403 otherwise), each writing an `audit_logs` row (`platform.complimentary_set` / `platform.complimentary_cleared`). Set: `status = 'complimentary'`, the note/actor/time stamped, `grace_ends_at`/`locked_at` nulled. Clear: `status = 'trialing'`, `trial_ends_at = now() + 14 days`, `grace_ends_at`/`locked_at`/comp fields nulled. **Why most readers need no change:** `'complimentary'` is a status outside `{trialing, past_due, locked}`, and every warning/lock decision filters on those — `sweep_platform_billing` selects only `trialing`/`past_due` (so a comp studio is never lapsed, warned or locked), `studio_is_locked` is `status = 'locked'` (false for comp), and `staff_bootstrap`/`member_bootstrap` compute `billing_locked` as `status = 'locked'` (false), so the staff/member gate never locks a comp studio. **The one function that would overwrite it is the Stripe webhook:** `stripe_platform_handle` is re-issued to return early (`'ignored_complimentary'`) for a comp studio, so a stray `invoice.paid` / `payment_failed` / `checkout.session.completed` / `subscription.deleted` can never flip it off complimentary. **UI:** `/admin/billing` gains a per-studio "Make complimentary" (note required) / "Stop complimentary" control, the status rendered `complimentary · since {date} · {note}`; the member `/billing` page for a comp studio shows the sentence and no Stripe button, and the "Payment needed" banner never shows. **Also fixed here (bug):** `/admin/billing` used `staffScreen()`, which requires a studio staff context, so a platform-admin login that is staff of no studio was redirected to `/admin` (the "Studio billing" link looped) — rebuilt on the `/admin` frame (`AdminShell` + `is_platform_admin`, no `staffScreen`).

**Where:** Platform billing (migration 044/046 family); `platform_subscriptions`; `/admin/billing`; the member `/billing` page. **Status:** settled. **Extends:** the platform-billing model (a studio pays Studiior). **Reuses:** `is_platform_admin`, the existing status-filtered sweeps/gate (unchanged), `audit_logs`.

---

## 51 — The studio's app on the home screen (per-tenant PWA)

Each tenant's member app installs to a phone's home screen as that studio's own app: its name, its logo as the icon, its accent as the theme colour, opened full-screen. The instructor portal installs separately as "{Studio} — Instructors". A public Install page per tenant (`{slug}.studiior.app/install`) carries the logo, a QR code and iPhone/Android instructions, for the website's "Download the app" button. Members see a one-time "Add to your home screen" card after first sign-in, and the instructions live under Settings. Settings → Branding gains an editable login tagline, an install welcome line, and the public instructor-name rule (first name only, or full name) used by the website schedule. Everything derives from Branding — no per-tenant files are hand-made. The word "Studiior" appears nowhere a member sees. Deanna, 2 Oct 2026.

**Mechanism.** Two nullable `studios` columns — `login_tagline` (the sign-in sub-line, default shown "Book your classes, check in, and see your plan.") and `install_welcome` (the Install-page line, default "Add {studio} to your home screen for one-tap booking.") — edited in Settings → Branding with a live login-sheet preview. `studio_by_slug` (the one anon pre-login lookup, migration 004 — one of the TWELVE anon surfaces) returns both; it is a `returns table`, so adding columns is a DROP + recreate that re-grants anon/authenticated/service_role and re-asserts exactly twelve. **Icons** are generated, never hand-made: a route on the member host renders the studio logo onto a square of the accent (or the neutral initial letter when there is no logo) at 180 / 192 / 512 and a maskable 512 with safe padding, via `next/og` `ImageResponse` (bundled with Next, on Vercel's runtime — **`sharp` is not a dependency and is not used**), cached immutably with a version derived from the logo URL so a new logo busts it. **Manifest** `/manifest.webmanifest` per tenant: name, short_name (studio name), `start_url`/`scope` "/", `display` "standalone", `background_color` (paper), `theme_color` (accent), the generated icons, `id` the slug; `/instructor/manifest.webmanifest` is the same with name "{Studio} — Instructors", `start_url`/`scope` "/instructor". The member layout links the member manifest + apple-touch-icon + `apple-mobile-web-app-title` + theme-color; a new instructor layout links the instructor manifest with its own title. **Install page** `/install` (public, anon lookup only) — logo, name, `install_welcome`, a server-generated QR of the page URL (the `qrcode` dependency, no third-party), iPhone (Safari → Share → Add to Home Screen) and Android (Chrome Install / ⋮ → Add to Home screen) sections, platform detected from the user agent, a real Install button where `beforeinstallprompt` fires, and "Already installed? Open the app"; same page at `/instructor/install`. **The Home card** is a one-time "Add {studio} to your home screen" → `/install`, dismissed into a `member_dismissals` row (key `install_card` — the migration-166 durable-per-member pattern, NOT localStorage) and hidden in standalone mode (the `display-mode: standalone` media query). Settings gains "Add to home screen" → `/install`. **The staff app (`app.studiior.com`) is unchanged.**

**Routing note.** The icon/manifest routes live in the member subtree and resolve the slug from the request host like every member page; the middleware matcher excludes `.png`, so the icon routes use extension-less paths (`/icon/192`, `/icon/180` for apple-touch) referenced from the manifest and the `<link>` — iOS and Android key on the Content-Type and the manifest `type`, not the URL suffix.

**The public instructor-name rule.** `studio_settings.public_instructor_name` (`text not null default 'first' check in ('first','full')`) governs how an instructor is named on the WEBSITE schedule (the `public_schedule` embed) only — the member app and staff screens are unchanged. `public_schedule` fills `instructor_first_name` with `split_part(display_name, ' ', 1)` when `'first'` (the default and today's behaviour) or the full `display_name` when `'full'`; the column name is kept for embed compatibility, and the embed's `initials()` takes up to two initials so a full name renders two. Set in Settings → Branding ("Instructor names on the website: First name only / Full name"). Default `'first'`, so the `all_off` canary and every existing studio are unchanged.

**Where:** Data Model (the two `studios` columns); `studio_by_slug`; migration (columns + drop/recreate). **Status:** settled. **Extends:** Decision 29 (member-app branding), Decision 41 (per-request member host), Decision 166's `member_dismissals`. **Reuses:** Branding (logo/accent/preset), `studio_by_slug`, `next/og`, `qrcode`, `member_dismissals`. **The word "Studiior" appears nowhere a member sees** (the long-standing member-app rule).

---

## 49 — Members overview filters, a Sales history page, and membership actions

The staff app shows plan and payment history across members, not only one member at a time, and gives staff the controls a membership needs. (1) Membership actions (none existed): End membership, Freeze/Unfreeze, Extend expiry, Mark paid, Record refund — each a guarded SQL function with an audit row and a sentence result; the member is emailed for End and Freeze; a refund is recorded here, never pushed to Xendit (a Xendit refund is done in the Xendit dashboard and then recorded). (2) Members list: beside the health-band filters, plan filters — On a plan (an active membership or pack with credits), Expiring in 14 days, Expired, Free class only (had their free class, never bought — the conversion list), No plan yet — and columns for current plan and expiry/credits. (3) A Sales page (/sales) reachable from the dashboard revenue tile and the Selling menu: every plan purchase newest first with member, plan, type, amount, payment source, bought on, starts, expires, status (active / expiring / expired / refunded / unpaid / frozen), filters by plan, status and month, a totals line for the filtered set, CSV export, and per-row the membership actions above. Owners and managers; front desk sees the Members filters but not Sales amounts. Every figure computed in SQL; times via fmt_clock. Deanna, 3 Oct 2026.

**Mechanism — the actions.** Five manager-up SQL writers, each an audit row (`membership_events`) and a sentence result: `end_membership(membership, keep_credits, reason)` (status→cancelled, credits forfeited via a `credit_ledger` row unless kept, future bookings left in place and counted in the sentence, member emailed `membership_ended`); `freeze_membership(membership, until)` / `unfreeze_membership(membership)` (honours `plan.freeze_allowed`/`max_freeze_days` with a PT422 sentence, sets `freeze_start=today`/`freeze_end=until`, status→frozen, pushes `expires_on`/`renews_on` by the frozen days on unfreeze, member emailed `membership_frozen`); `extend_membership(membership, new_expires_on, reason)` (reason required); `mark_membership_paid(membership, amount_cents, method)` (a succeeded `payments` row + membership active, refuses if already paid). **The refund keeps ONE implementation.** `record_refund(payment_id, amount_cents, reason)` already exists (migration 040, payment-keyed, manager-up, partial/full, credit forfeit on full, membership cancel on full, audit). The membership-level action named in the decision, `record_refund(p_membership_id, …, p_end)`, is built as **`refund_membership(membership, amount_cents, reason, end)`** rather than an overload of the existing 3-arg `record_refund` (two `record_refund`s differing only by a trailing boolean is the 028 overload footgun) — it resolves the membership's originating succeeded payment and **delegates to `record_refund(payment_id,…)`** so Sales and the dashboard share one refund definition, applies `p_end` for a partial refund that should also cancel, and **never calls Xendit**: the sentence is *"Recorded. Refund the money in Xendit if it was paid there."* **The `membership_frozen` booking reason.** `book_class` is re-issued from its newest definition with one early gate: a member whose only usable plan is frozen-now is refused with reason `membership_frozen` and the sentence *"Your membership is paused until {date}."* (a non-frozen pack with credits still books). **Reads.** `member_plan_overview(studio)` (desk-up, **no amounts**) returns per non-archived member the list fields + `current_plan_name`, `plan_type`, `status`, `expires_on`, `credits_remaining`, `had_free_class`, `has_ever_paid`, and `plan_state ∈ (on_plan, expiring, expired, free_only, none)` — an expired pack then an active membership is `on_plan`; `expiring` is within 14 studio-local days; `free_only` requires a `guest_passes` (free-first, host-null) row and no paid membership ever. `sales_history(studio, from, to, plan_id?, status?)` + `sales_totals(…)` (manager-up) derive status and the paid total through the SAME `studio_revenue_between` / `status in ('succeeded','partially_refunded')` set `dashboard_revenue` uses, so the Sales totals and the dashboard never disagree for a month. **UI.** `/members` gains a second (plan) filter row combinable with the health filter + current-plan/expiry/credits columns; the member page gains an Actions row on the live membership (past memberships read-only); `/sales` (manager-up) is the table + filters (plan/status/month, defaulting to this month) + totals + server-rendered CSV export + the same per-row actions; the dashboard revenue tile and the revenue chart page link to `/sales?month=this`; the Selling menu gains "Sales". Front desk sees the Members filters, never Sales. Every figure SQL; times via `fmt_clock` (Decision 55); email dates carry the year (Decision 33 amendment).

**Where:** new migration (6 writers incl. `refund_membership`, 2 readers, `book_class` re-issue, 2 templates); `/members`, `/members/[id]`, new `/sales`, the revenue page + dashboard tile, `lib/nav.ts`. **Status:** settled. **Extends:** Decision 16 (manual payments / `record_refund`), Decision 23 (membership periods / who owes), Decision 12 amendment (drop_in/trial are packs), Decision 40 (Xendit — refunds stay in its dashboard). **Reuses:** `studio_revenue_between` + `dashboard_revenue`'s paid/refunded set, `record_refund`, `membership_events`, the notification pipeline, `fmt_clock`, `formatMoney`.

---

## 48 — Hide unstaffed classes from members, per tenant

Decision 17 made an open shift publishable and bookable by members. A studio may instead keep a class off the member side until an instructor is on it. Per-tenant switch `studio_settings.hide_unstaffed_from_members`, OFF by default product-wide (`all_off` canary), ON for Reform Collective. When on: a scheduled class in a published month with `staffing <> 'assigned'` is not listed in the member app (schedule, class page by id, Home, free-first list), not returned by `public_schedule` (the website embed), and `book_class` / `book_first_free` / `book_guest` refuse it with reason `'not_staffed_yet'` and the sentence "This class isn't open for booking yet." Existing bookings on a class that later loses its instructor are untouched — the class stays visible to those members and on their calendar feeds, just closed to new bookings until someone is assigned. Staff screens, instructor screens, open-shift claiming (Decision 17) and cover (Decision 18) are unchanged. "Assigned" means `staffing = 'assigned'` — a Decision 38 confirmation still pending does not hide the class. Deanna, 1 Oct 2026.

**Mechanism.** One predicate `occurrence_member_visible_run(p_occurrence_id, p_member_id default null)` — the existing visibility rules (published month, scheduled) AND (the switch off OR `staffing = 'assigned'` OR `p_member_id` holds a non-cancelled booking on this occurrence). Every member reader and the three booking writers go through it. The booking refusal (`not_staffed_yet`) sits with the occurrence checks, before the booking window, mirroring `month_not_published`. `public_schedule` applies the same staffing rule with no booking exception (it has no caller). The member calendar feed keeps the classes the member is booked on and otherwise applies the same rule. "Assigned" is `staffing = 'assigned'`, so a pending Decision 38 confirmation (still `assigned`) never hides the class.

**Why `staffing`, not `instructor_id`.** `tg_derive_staffing` keeps `staffing` and `instructor_id` in lockstep (`'open'` iff no instructor), and `staffing` is what Decision 17's open-shift state is expressed in — a class in the open-shift/cover flow is exactly `staffing <> 'assigned'`, which is what this hides.

**Where:** Business Rules §2 (booking gate); Data Model §5; migration (the column + the predicate + the re-issued readers/writers). **Status:** settled. **Extends:** Decision 17 (open shift — now hideable), Decision 25 (published-month visibility), Decision 30 (free-first list). **Reuses:** the existing member-visibility rules, `month_not_published`'s refusal placement, the `all_off` canary opt-in-off-by-default shape.

---

## 47 — Staff can cancel a specific class (or the rest of its weekday this month) from the Schedule

Staff (manager-up) can cancel one scheduled class, or that series' remaining classes on the same studio-local weekday in the same month, from the Schedule panel and the roster page. It goes through the existing `cancel_occurrence` path, so booked members get the Business Rules §3.2 treatment (credit back regardless of timing, fee waived, `class_cancelled` email, calendar cancellation) and the instructor, if any, is told. New `cancellation_cause` `'no_instructor'` for the case this exists for — nobody available to teach — which pays nobody (there is no instructor). The other staff-chosen causes are offered too: `studio_fault` (pays the assigned instructor base, as Decision 22 says), `force_majeure` (pays nothing). The recurring class (series) is never touched — cancelling November's Mondays leaves December's Mondays on the calendar. A cancelled class stays visible on the staff Schedule as cancelled, not deleted. Deanna, 1 Oct 2026.

**Mechanism.** `cancel_occurrences_for_period(p_occurrence_id, p_scope in ('one','month'), p_cause cancellation_cause, p_reason text)` — a manager-up guarded wrapper over a service-role `_run` twin. It resolves the target set exactly as `assign_occurrences_for_period_run` does after the 42a amendment (a): 'one' = this occurrence; 'month' = this series' scheduled occurrences in the same studio-local calendar month, same studio-local weekday as the clicked class (never the series' other weekdays), with `starts_at >= this one`. It skips already-cancelled/completed occurrences and calls `cancel_occurrence` per target inside a savepoint, so one failure never aborts the batch. `p_cause` is restricted to `no_instructor | studio_fault | force_majeure` — never `unmet_minimum` (that is the flex sweep's own cause, Decision 21) or a closure cause (Decision 44 owns those). `no_instructor` on a class that HAS an assigned instructor is refused PT422 ("This class has an instructor — choose a different reason."). `no_instructor` writes no pay record (there is no instructor to pay); `studio_fault` pays the assigned instructor base and `force_majeure` pays nothing, both through the existing `cancel_occurrence` → pay path (Decision 22). Returns `{cancelled, skipped:[{occurrence_id, when, reason}], members_affected}`, one audit row per call.

**The enum value is added in its own migration step** (CLAUDE.md's rule: a new enum value cannot be USED in the transaction that adds it), then the function migration follows.

**UI.** The Schedule block panel and the roster header gain a "Cancel this class" control opening a confirm: a cause radio (No instructor available / Studio's own reason / Beyond anyone's control), an optional reason line, a scope (Just this class / Every {weekday} this month), and the count — "N members are booked across these classes — they'll get their credit back and an email." The result sentence reads "Cancelled 4 classes. 1 member told." A cancelled class keeps rendering on the Schedule (not deleted); its panel shows the cause and reason and no Assign control.

**Where:** Business Rules §3.2; Data Model §5; Decision 22 (pay by cause); migrations (the enum step + the function). **Status:** settled. **Extends:** Decision 42a (same-weekday scope from the Schedule), Decision 22 (cancellation pay by cause), Decision 21 (flex cancellation path unchanged). **Reuses:** `cancel_occurrence` (the §3.2 path, the only credit-returner), `assign_occurrences_for_period_run`'s target-set resolution.

---

## 45 — Instructors enter their monthly availability on their phone, and every instructor notification link points at the tenant portal

Instructors enter and submit their monthly availability from their phone, inside the tenant instructor portal (`{slug}.studiior.app/instructor/availability`), using the same month-submission mechanism the desktop editor uses (`availability_submission_week` / `submit_availability`; draft → submitted → approved / changes_requested; the whole week saves as ONE payload). The portal editor is the Calendly-style pattern already in the desktop week editor — per weekday time ranges plus copy-a-day — laid out phone-first. All instructor-facing notification links are absolute and point at the tenant portal, built by one helper so they cannot drift. The desktop editor stays for managers.

**What started this.** The availability-due email rendered its link as `http:///instructors/<id>/availability` — no host, and a staff-host path — because the sender put a bare relative staff path in `href` and nothing prefixed it. And the portal's read-only availability view linked to `/my/availability`, which 404s on the tenant host. Two bugs, one class: instructor mail and the instructor portal were pointing at the staff app.

**Part A — the phone editor.** `app/member/instructor/availability/page.tsx` becomes the editor, not a read-only view with a link out. It collects the same month the desktop does (next month by default, `?p=YYYY-MM-01` to open another), shows the shared `STATUS_LINE` and the `changes_requested` note, and renders seven day cards (each showing its ranges or "Not available"). Tapping a card opens a bottom sheet (the member app's `m-sheet` CSS, driven by in-component state rather than the intercepting-route `Sheet`, because the whole week is one client form and nothing is saved until the sticky bar) with From/To `<input type="time">` rows, "+ Add another range", a "Not available" toggle, and "Copy to…". A sticky bar posts the WHOLE week through a portal server action (`submitMyAvailability`) that calls `submit_availability` with the same draft/submit distinction the staff action uses. Validation (`from < to`, no overlap within a day, 15-minute steps) is extracted to `lib/availability.ts` and used by both editors; the database's `to > from` check remains the boundary. Status rules exactly as desktop (approved → read-only, submitted → still editable, none/draft → editable). Home shows an "availability due" prompt when the collected month is not yet submitted, dated from `availability_due_day`. **No new SQL for Part A** — `submit_availability` / `availability_submission_week` already take and return this exact shape.

**Part B — one helper, every instructor link absolute.** New SQL `instructor_portal_url(p_studio_id, p_path)` returns `https://{slug}.{member_app_domain}{path}` (default domain `studiior.app`), so an instructor-facing link is one function call and cannot drift into a staff path. The senders whose instructor link was wrong are re-issued from their newest definitions to use it: `queue_availability_reminders` (`availability_due` → `/instructor/availability`), `sweep_week_confirmations` (`week_confirm_ask` + `week_confirm_reminder` → `/instructor/schedule`), `request_cover` (`cover_available` → `/instructor/shifts`), and `approve_shift_application` + `decline_shift_application` (`shift_declined` → `/instructor/shifts`). The `availability_due` and `availability_changes_requested` template copy changes from "Open the staff app" to "Open your instructor app". **Links to a STAFF recipient stay on the staff origin** — `applications_url`, `shifts_url` for a manager, `cover_url` (`/shifts/cover`, the manager's arrange-cover page), `billing_url` — and the member booking links (`/class/{id}`) are unchanged. The senders that already emit `https://{slug}.studiior.app/instructor/...` inline (`queue_assignment_request`, `sweep_instructor_class_reminders`, `queue_instructor_booking_alert`, `publish_month`, `notify_open_shifts`) are left as they are; routing them through the helper is a zero-output refactor deferred to keep the migration focused.

**Where:** Business Rules §3.3, §5; Data Model §5; migrations 066 (availability), 067/112 (week confirmation), 054/161 (cover), 048 (shifts). **Status:** settled. **Extends:** Decisions 18, 25, 57. **Reuses:** the member app shell and `m-sheet`, `submit_availability`.

---

## 44 — Studio opening hours

A studio may set one opening window (`open_time`, `close_time`, studio-local) in Settings → Studio. Optional and unset by default product-wide: with no hours set, nothing anywhere changes (the `all_off` canary holds). A class is INSIDE opening hours when its START time falls within `[open_time, close_time]` — the end may run past close (Reform's last class is 22:00–22:50 with a 22:00 close; a studio closes when the last class ends). A class outside hours is a WARNING at creation (one-off and series) and on a drag, never a block — the same posture as Decision 37 amendment (c) for availability. When hours are set, the staff Schedule's Day and Week views span the opening window (plus any class outside it) instead of deriving the visible hours from the classes present. Per-weekday hours and closures-by-date are deferred; the existing closures mechanism is unchanged. Deanna, 30 Sep 2026.

**Schema + the predicate.** `studio_settings.open_time`/`close_time` (`time`, null) with a CHECK — both null (not set) or both set with `open_time < close_time`. `occurrence_outside_hours(studio, starts_at)` (SECURITY DEFINER, service-role only, no caller guard — it reads only the studio's own settings) is the one test: false when hours are unset, else the studio-local start time is outside `[open, close]`. `create_occurrence` and `move_occurrence` (re-issued from their newest definitions, create-or-replace) append `'outside_hours'` to their `warnings` array when it returns true — alongside `outside_availability` and `standalone_flex`, never a refusal.

**The copy is a pure builder** (`outsideHoursSentence` in `lib/flex-copy.mjs`, node-tested), like `standaloneFlexSentence`: `" It starts outside the studio's opening hours (06:00–22:00)."` for a one-off, `" These start outside the studio's opening hours (06:00–22:00)."` for a series, empty when the window is unset. The window is formatted HH:MM (24-hour, as the staff app shows time). The series paths compute the warning in TS (`seriesOutsideHours`, comparing the series' `time_of_day` against the window) since a series is a `class_series` row materialised by a trigger, not a `create_occurrence` call; `/series/new` carries it to the series detail banner via a query param, the calendar modal renders it inline, and a drag's notice adds "that is outside the studio's opening hours".

**The visible hours.** `hourBounds` (`lib/schedule-bounds.mjs`) gains optional open/close minutes: when set, `minHour = floor(open)` and `maxHour = ceil(close)+1`, then WIDENED (never narrowed) to include any class outside the window — a 05:30 class pulls minHour to 5, a 22:00–22:50 class at a 22:00 close pushes maxHour to 24 (the `hour>=24` clamp in `wallAt` keeps `max` on the anchor day, the strip-at-the-bottom regression). Unset → exactly today's class-derived behaviour. The Schedule page passes the studio's hours in.

**Migration 190** (`20260831950000`). Tests: `test/opening_hours_test.sql` (space `0d44`, 14 assertions — the CHECK both ways, the predicate inside/outside/unset, a Manila 07:00 judged in the studio zone, and `create_occurrence` warning-not-blocking at 22:15/05:45 and silent at 22:00 and unset) + node tests for `hourBounds` (window-only, widened to 5, the 22:50 regression) and `outsideHoursSentence`. Browser-verified: Settings → Studio saves 06:00–22:00 and clears; a 22:15 one-off renders the warning and is created; the Day view shows the 06:00–23:00 gutter on a day whose classes end at 12:50.

**Where:** Business Rules §5; Data Model §5; migration 190. **Status:** settled. **Extends:** Decision 37 amendment (c) (warn, never block). **Reuses:** `create_occurrence`/`move_occurrence`'s warnings array, the flex-copy pure-builder pattern, `hourBounds`.

---

## 43 — Automatic instructor assignment is a per-tenant switch, off by default

Automatic instructor assignment is a per-tenant switch, `studio_settings.auto_assign_open_classes`, OFF by default product-wide (`all_off` canary). When off, materialising a series never assigns anyone: occurrences are created unassigned (`staffing 'open'`, no instructor line per Decision 17), and no sweep assigns later. When on, today's behaviour (`tg_assign_after_series → assign_instructors_run`) is unchanged. Reform Collective leaves it off: the owner assigns by hand from the Schedule against the availability instructors submitted (Decision 45), and whatever stays open is offered to instructors as open shifts (Decision 17). Deanna, 1 Oct 2026.

**Mechanism.** `auto_assign_enabled(studio)` (SECURITY DEFINER, reads the one column, defaults false) is the predicate every AUTOMATIC engine entry gates on. The automatic paths — `tg_assign_after_series` (the materialise/series-edit trigger) and the availability auto-fill (`set_instructor_availability`, `submit_availability`, `approve_availability_submission`, each of which called `assign_instructors_run` after an availability change) — return early / skip the engine call when the switch is false. The **manual** `assign_instructors` ("fill a month") wrapper is UNGATED: it is a deliberate manager action, not automatic, and `assignment_test.sql` exercises it directly. So a switch-off studio's engine never fires on its own, while a manager who explicitly clicks "fill" still can.

**Where:** Data Model §5; migration 193. **Status:** settled. **Extends:** Decision 17 (unstaffed → open shift), Decision 45 (hand-assign against submitted availability). **Reuses:** the `all_off` canary pattern, the per-tenant opt-in-off-by-default shape.

---

## 42a — Assignments are made per class or per period from the Schedule, not on the series template

Assignments are made per class or per period from the Schedule, not on the series template. Clicking a class opens Assign: an instructor dropdown (all active instructors; an availability mismatch is a warning per Decision 37 amendment (c), never a block) and a scope — 'Just this class', 'Every week this month' (this series' occurrences in the same studio-local calendar month, from this class forward), or 'Until <date>'. Each occurrence is written through the existing single-occurrence assign path so Decision 38's confirmation request, the double-booking exclusion constraints and the audit all apply unchanged; an occurrence that would double-book the instructor is skipped and listed, never silently reassigned. The series template's instructor is untouched — a series may carry no instructor at all, and normally does. Unassign is the same control with the same scopes; an unassigned occurrence returns to 'open' and any pending Decision 38 request for it is withdrawn. A manager may also clear every assignment in a month from the Publish page in one action, allowed when the month is unpublished OR has no member bookings (Decision 25 offers no unpublish by design, so the clear cannot require one); a published month with bookings is refused and assignments are changed class by class from the Schedule instead. Deanna, 1 Oct 2026.

**Mechanism.** `assign_occurrences_for_period(p_occurrence_id, p_instructor_id | null, p_scope in ('one','month','until'), p_until date, p_confirmed boolean)` — a manager-up guarded wrapper over a service-role `_run` twin. It resolves the target set ('one' = this occurrence; 'month' = this series' scheduled occurrences in the same studio-local month with `starts_at >= this one`; 'until' = this series, this one through `p_until` inclusive; a one-off with no series collapses every scope to just this occurrence) and, per target, calls the EXISTING single-occurrence path: `reassign_occurrence` for an assign (→ `move_occurrence`, so Decision 38's request-stamping triggers, the GiST exclusion constraints and the audit all apply), `move_occurrence(p_clear_instructor => true)` for an unassign. A refusal (`instructor_busy` from the exclusion constraint, `outside_availability_dates` from the hard validity gate) is caught per occurrence and recorded as a skip with a human reason; a raw `23P01` is also caught so one clash never aborts the batch. `p_confirmed true` = Decision 38's bypass tick: after each assign it calls `mark_assignment_confirmed` (stamps `assignment_confirmed_by`, cancels the now-empty digest); `p_confirmed false` lets the AFTER trigger queue the one coalesced request per instructor per day. Availability (the Decision 37c HOURS warning, via `instructor_available_at_run`) is surfaced as an aggregate `outside_availability` warning, never a block — the validity-DATES hard refusal in `move_occurrence` is a skip, and does not fire for Reform's instructors (all `valid_on` everywhere). Returns `{assigned, skipped:[{occurrence_id, when, reason}], warnings}`. Never touches `class_series.instructor_id`.

**The month-clear.** `clear_month_assignments(p_studio_id, p_month date, p_clear_templates boolean)` (manager-up). Refused with PT409 only when `month_published(studio, month)` AND the month has any member booking `status <> 'cancelled'` ("This month is published and members have booked into it — change assignments class by class from the Schedule instead."); allowed for a draft month (publication on, not yet published — `month_published` false) with or without bookings, and for any month with zero non-cancelled bookings. Unassigns every scheduled occurrence in the studio-local month through the same `move_occurrence(p_clear_instructor)` path and withdraws the pending digests; returns the count. `p_clear_templates` (default ON in the UI): sets `class_series.instructor_id = null` for series with occurrences in that month, so FUTURE months start unassigned — template only; existing occurrences in OTHER months are untouched. (At a switch-ON studio, nulling the template re-fires `tg_assign_after_series`; the clear is a tool for the hand-assigning switch-OFF studio, where the Decision-43 early-return makes the template clear stick.)

**UI.** The Schedule block panel's Assign section gains the "Unassigned"-at-top dropdown, the three scope radios (with the 'Until' date input), the "Already confirmed with the instructor — don't ask them" tick (default ticked, as on the create form), and the result sentence ("Assigned Ada to 4 classes. Skipped 1: Mon 10 Nov 07:00 — Ada already teaches Reformer Flow at that time." plus the availability-warning sentence where applicable). Unassigned classes show no instructor line (Decision 17), never TBC/TBD. The Publish page gains "Clear all instructor assignments for this month" behind a confirm, shown on a qualifying month and the refusal sentence otherwise.

**Where:** Business Rules §5; Data Model §5; migration 193. **Status:** settled (42a only; 42b — bulk edits on `/series` — is a separate later build). **Extends:** Decision 38 (confirmation request), Decision 37 amendment (c) (availability warns), Decision 25 (no unpublish), Decision 17 (open shift). **Reuses:** `reassign_occurrence`/`move_occurrence` (the single-occurrence path), `mark_assignment_confirmed`, `queue_assignment_request`, the block panel.

### Amendment — the owner may clear a published month with bookings (Deanna, 1 Oct 2026)

clear_month_assignments may run on a published month that members have booked into, but only by an OWNER (not a manager), with an explicit acknowledgement. Member bookings are never touched by it — only the instructor comes off each class and the class becomes an open shift until assigned. Managers still get the refusal. Deanna, 1 Oct 2026.

**Why:** Reform's November is published (auto-published when publication was turned on, because eight real members had already booked) and the owner needs to strip the auto-assigned instructors from all 346 classes and assign by hand (Decisions 43/42a). Cancelling members' bookings to qualify is not acceptable, so the published+bookings refusal needed an owner-only exit.

**Mechanism (migration 194).** `clear_month_assignments` gains `p_acknowledge boolean default false` (a signature change, so the 3-arg function is DROPPED and recreated 4-arg, ACLs re-asserted — the 028 trap). Today's rule is kept; the published-AND-bookings branch now allows the clear when the caller is the studio OWNER (`coalesce(is_owner(p_studio_id), false)`, null-safe) AND `p_acknowledge` is true, otherwise the same PT409 sentence. A manager with acknowledge still gets PT409. The per-occurrence unassign path is byte-for-byte unchanged — `move_occurrence(p_clear_instructor => true)`: member bookings are untouched (`move_occurrence`'s member notification is gated on `v_moved and booked_count > 0`, and clearing the instructor is not a time move so `v_moved` is false; `queue_instructor_assigned` is skipped because the cleared instructor is null), pending Decision 38 requests are withdrawn, and `staffing → open`. **No member notification is queued** by the clear, confirmed by reading `move_occurrence`.

**UI.** On the Publish page, a published month with bookings shows the OWNER (not a manager) the sentence *"This month is published and N members have booked into M classes. Their bookings stay exactly as they are; every class becomes an open shift until you assign it. Members are not told."*, then a tick *"I understand — members' bookings are not affected"* and the Clear button (disabled until ticked), with the same "also remove from the recurring classes" tick as a draft-month clear. A manager still sees the refusal sentence.

**Status:** settled. **Extends:** this Decision (42a) and Decision 25 (no unpublish — so the only exit is an owner acknowledgement, never a withdrawal of the publication). **Reuses:** `is_owner`, the unchanged per-occurrence unassign path.

### Amendment — scope is the same weekday, and the dropdown defaults to the current instructor (Deanna, 1 Oct 2026)

**(a) Scope = same weekday.** A series may run on several weekdays with different instructors per day ("every Monday and Thursday at 11:00", Nikko on Mondays, Joseph on Thursdays). The 'month' and 'until' scopes resolve to the same series AND the same studio-local weekday as the clicked class, never the series' other weekdays. `assign_occurrences_for_period_run` adds `and extract(dow from starts_at at time zone <studio tz>) = <dow of the clicked occurrence>` to both scopes. Labels read "Every Thursday this month" / "Every Thursday until…", the weekday taken from the clicked class. The same weekday rule governs the Decision 47 cancel scopes.

**(b) The dropdown defaults to the current instructor.** The Assign dropdown includes and defaults to the class's current instructor (the block panel previously filtered them out, so a scope could not be applied to the same person without re-choosing them). When the class has an instructor the dropdown defaults to them at the top of "Qualified and available", labelled "{name} (current)"; "Unassigned" stays available. The button reads "Assign" when the chosen instructor differs from the current one, "Apply to {weekday}s this month" / "Apply until…" when it is the same person with a wider scope, and is disabled for "Just this class" with the same instructor. Server-side, the same instructor on an already-assigned occurrence is a no-op for that one and the rest of the scope is assigned.

**Status:** settled. **Extends:** this Decision (42a). **Reuses:** `assign_occurrences_for_period_run` (the weekday filter added to its existing scope resolution), the block panel.

### Amendment (c) — drag safety, and the top-up never re-creates a moved slot (Deanna, 2 Oct 2026)

On hosted, two Reform series ended up with occurrences at a second clock time on the same weekday (a Wed 07:00 series with 18:00 copies; a Sat 17:00 series with 09:00 copies). The most likely cause: a Day-view drag that changed the **time** as well as the instructor column (a slip between columns that also moved vertically), after which the nightly top-up (`generate_occurrences`) re-created the vacated slot — so the class read as *moved and also still there*. The scope bug this exposed (a period scope that swept both times) is fixed in migration 199; this amendment removes the CAUSE and makes any strays visible and fixable.

**(1) A drag that changes the TIME confirms; a drag that only changes the instructor column does not.** On the staff Schedule, a drag whose start instant differs from the class's current one opens a confirm — *"Move {class} from 07:00 to 18:00 on Wed 11 Nov? {n} members are booked and will be emailed."* — with Move / Cancel; a drag that keeps the time and only changes the resource column keeps today's behaviour (the instructor swap, which does not email members). This is distinct from the existing booked-members confirm (which only fires when members are booked): a time change always asks, because an unintended retime is the failure here. **Day view additionally snaps the drop to the original time unless the vertical movement exceeds one full slot**, so a drag that lands a class in a different instructor's column without a deliberate vertical move never retimes it — the slip that produced the strays can no longer change the time by accident.

**(2) The top-up treats a moved class as moved, not missing.** `generate_occurrences` must not re-create a slot for a series on a studio-local day where an occurrence of that series **already exists at any time** — so a class dragged from 07:00 to 18:00 on a Wednesday leaves one Wednesday occurrence, and the next nightly run does not add a 07:00 back. (Until now the materialise guard keyed on `(series_id, series_slot_at)` and the exact start instant; a moved occurrence keeps its `series_slot_at`, but a top-up that computed a fresh slot for that date and found nothing at that precise instant re-created it.) The per-day-per-series rule is the backstop: one class per series per day, wherever on that day it sits.

**(3) Strays are visible and fixable on the series page, never auto-corrected.** The series page gains a "Classes not at the usual time" list — its future scheduled occurrences whose studio-local time or weekday differs from the template's `time_of_day` / `BYDAY` — each with a "Move back" link that calls `move_occurrence` to the template time on that occurrence's own date. No automatic correction: a stray may be deliberate, and moving a class members have booked emails them, so it stays a one-click manager action.

**Status:** settled. **Extends:** this Decision (42a), Decision 37 (series editing / materialisation), Decision 2 (a significant move's free cancellation). **Reuses:** `move_occurrence` (the time-change confirm is its existing booked-members path; "Move back" calls it), `generate_occurrences` (the per-day guard added to its existing slot resolution).

---

## 42b — Bulk changes to recurring classes from the list

On the Recurring classes list a manager selects any number of series and applies one change to all of them: minimum bookings, tier (core/flex/always), room, end date, start date, or the template instructor (including Unassigned). A preview lists exactly what will change per series before anything is written; the apply goes through the SAME single-series functions the series page uses (`set_series_guarantee`, `update_series`, and the template instructor write) one series at a time inside one transaction with a savepoint per series, so every existing rule, warning and refusal applies unchanged; one audit line records the batch. Tier/minimum/room/date changes apply to the series and its future scheduled occurrences exactly as the single-series page does today — no new propagation rule; a room change that would double-book the room on some occurrence is refused for that series and listed. A start-date change on a series whose earlier occurrences have bookings is refused for that series and listed, never forced. The template instructor is a seed for future materialisation only (Decisions 42a/43): changing it never touches existing occurrences. Deanna, 1 Oct 2026.

**Mechanism.** `bulk_update_series(p_series_ids uuid[], p_change jsonb, p_preview boolean)` — a manager-up guarded wrapper over a service-role `_run` twin. The series must all belong to the caller's studio (resolved as `count(distinct studio_id) = 1` across the given ids, every id present; PT403 otherwise, before any work). `p_change` carries exactly ONE change: `{minimum}` / `{tier[, minimum]}` → `set_series_guarantee`; `{room_id}` / `{ends_on}` / `{starts_on}` → `update_series` (the room and date writer, which re-rooms/moves future occurrences and refuses `members_booked_on_dropped_classes` / `capacity_below_booked` exactly as the series page does); `{instructor_id}` → a direct `class_series.instructor_id` write under the `studiior.series_editing` flag (template only, trigger suppressed, no occurrence touched — the 42a/43 posture, since there is no single-series template-instructor writer to reuse). Each series runs inside a `begin … exception` subtransaction (savepoint); **preview** forces a rollback after calling the real function (with `confirm = true`, so a room clash surfaces as `update_series`'s non-empty `conflicts` array and is classified a refusal); **apply** keeps a clean result and rolls back only the one series that refuses or raises. A refusal is listed with the series name, its "Mon 07:00" slot and a human reason (a room clash → "the room is taken on some of its classes"; `members_booked_on_dropped_classes` on a start-date change → "earlier classes have bookings", on an end-date change → "later classes have bookings") — never silently applied. Returns `{ok, preview, change_type, changed:[…], refused:[{series_id, name, when, reason}], warnings:[{series_id, code}]}`; one `series.bulk_updated` audit row on apply. The standalone-flex warning from `set_series_guarantee` is carried through as a `standalone_flex` warning per series.

**The seventh change type — `{free_first_allowed}` — is NOT built**, because the Decision 30 amendment column (`class_series.free_first_allowed`) does not exist yet. When it lands, it is added as a seventh `p_change` shape.

**UI.** The list view (`/series?view=list`) gains a checkbox per row, Select all/none (over the active filter), and a "Change" bar — a dropdown (the six change types, the tier/minimum two shown only when guarantees or flex is on) with the matching input, a Preview button (disabled until at least one series is ticked), a preview table (Recurring class · change · note, scrolls inside its own container at phone width), and an Apply button carrying the count. The result sentence reads *"Changed N recurring classes. M refused: {name} {when} — {reason}; …"* (plus a standalone-flex line where applicable). The Grid view is not a selection surface — bulk edits are a list operation.

**Migration 195** (`20260832000000`). Tests: `test/bulk_series_test.sql` (space `b012`, 31 assertions — preview writes nothing (md5 unchanged); minimum/tier/room/ends_on applied to several series, past and cancelled occurrences untouched; a room clash refused and listed while the rest apply; a start-date change over booked earlier occurrences refused; the template instructor changed with the occurrence set md5 unchanged; foreign-studio and unknown ids PT403; a non-manager PT403; the audit row). Browser-verified as the Reform owner: a three-series minimum change previewed 3 rows and applied ("Changed 3 recurring classes.") with the series page reflecting the new minimum; a mixed end-date batch previewed one change + one refusal and applied to *"Changed 1 recurring class. 1 refused: Reformer Flow Mon 07:00 — later classes have bookings."*; at 375px no page overflow and the preview table scrolls in its container.

**Where:** Business Rules §5; Data Model §5; migration 195. **Status:** settled. **Extends:** Decision 42a (per-class/period assignment), Decision 37 (series editing). **Reuses:** `set_series_guarantee`, `update_series`, the `studiior.series_editing` flag, the single-series refusal reasons.

---

## 41 — The sign-up confirmation redirect is chosen per studio, not from the project-wide Site URL

A member signing up at `reformcollective.studiior.app` clicked the confirmation link and landed on the **staff login** at `app.studiior.com`. Cause: `signUp` called `supabase.auth.signUp` with no `emailRedirectTo`, so GoTrue used the project-wide **Site URL** — one value for every studio, and it points at the staff app. A multi-tenant platform cannot use Site URL for this: **the redirect must be chosen per request from the member host.**

**`emailRedirectTo` is built per request from the member host, never a hardcoded slug and never Site URL.** `signUp` (and `resetPasswordForEmail`) pass `${memberOrigin}/auth/callback?next=${next}` where `memberOrigin` comes from `currentMemberOrigin()` (the actual request `Host` — `https://{slug}.studiior.app` hosted, `http://{slug}.lvh.me:3000`/`.localhost` locally) and `next` is the signup/login page's own `?next` (the embed passes `/class/{id}`), default `/`. The builder (`buildAuthCallback`) and the open-redirect guard (`safeNext` — a RELATIVE path only; an absolute URL, `//host`, `/\`, control char or non-string collapses to `/`) live in `lib/auth-redirect.mjs` — plain ESM so `node --test` runs them without a bundler (this project has no JS test runner; Node 20 here cannot import a `.ts`), with a sibling `.d.ts` for the app.

**A new member callback route, `app/member/auth/callback/route.ts`**, handles both shapes GoTrue may send — `?code=` (`exchangeCodeForSession`) and `?token_hash=&type=` (`verifyOtp`) — establishes the session with the `@supabase/ssr` cookie client (a Route Handler can write cookies; a Server Component cannot), then redirects to `next` only if `safeNext` keeps it. On any failure it lands on the studio's own **member** `/login?error=confirm`. **The redirect base is the request's own `Host` header, not `url.origin`** — behind the middleware rewrite (and bound to `localhost` in dev) `url.origin` is the server origin, so redirecting there would send the member to the staff login, the very bug. The route lives in the member subtree so the middleware host rewrite reaches it, and middleware lets `/auth/callback` through **without a session** (there is none yet) — it rewrites into the member subtree but skips the session refresh so the route owns the cookie write. **The download routes and everything else are unchanged.**

**Supabase config.** `additional_redirect_urls` gains the local member globs (`http://*.lvh.me:3000/**`, `http://*.localhost:3000/**`) — without the host on the allowlist GoTrue silently ignores `emailRedirectTo` and falls back to Site URL, so this is load-bearing, verified locally (the confirmation email's `verify?redirect_to=` carried the member host, not Site URL). **Hosted `Authentication → URL Configuration` must list `https://*.studiior.app/**` in Redirect URLs**, and **Site URL is no longer relied on** (leave it at a neutral page). The confirmation email body is a **neutral, studio-agnostic** template (`supabase/templates/confirm.html`, wired in `config.toml` for local, pasted into the hosted dashboard once): "Confirm your email", one button, "You're creating an account to book classes with a studio that uses Studiior" — because auth templates are project-wide. Per-studio branding of auth emails is a **later decision** via the Send Email auth hook. The sender stays `Studiior <accounts@studiior.app>` (a dashboard SMTP setting; local shows the CLI default).

**No migration; anon surface stays eleven.** Tests: `test/auth_redirect.test.mjs` (`node --test`, 4) — member host → correct callback origin, `next` must be relative, absolute/`//`/backslash `next` rejected; and the callback live-tested (a bad `code` and a bad `token_hash` each → the member host's `/login?error=confirm`, an absolute `next` neutralised). The full chain was proven locally through real GoTrue: the confirmation email's link carries `redirect_to=http://reform.lvh.me:3000/auth/callback?next=%2Fclass%2Fabc123`.

**Amendment — the sign-up loop.** The callback established the session and redirected to `next` (default `/`), but a fresh self-signup has **no member row** until `claim_member_by_email` runs — which only happened when they tapped the finish button on `/signup`. So Home (which needs a member row) sent them to `/login`, login succeeded, Home again → `/login`: a loop. Reproduced on hosted with a fresh address. **The confirmation callback now attaches the member itself**: after the session is established, `app/member/auth/callback/route.ts` resolves the studio from the request host (`studio_by_slug`) and calls `claim_member_by_email(studio_id)` — the SAME function the finish button calls, so there is one attach path. A null `failure_reason` (attached, or already linked in this studio — idempotent) **or** `already_claimed` → redirect to the safe `next`; any other reason (`email_not_verified`, `no_such_studio`) → `/signup`, which still shows the finish button and the reason; a confirmed-but-unattached member is **never** sent to `/`. The decision is a pure helper **`confirmDestination(sessionOk, claimReason, next)`** in `lib/auth-redirect.mjs` (node-testable). **The belt:** `memberScreen()` used to redirect a null context to `/login` for both "no session" and "session but no member row" — the latter is the loop, so it now redirects a **signed-in** user with no member row to `/signup` (via `currentUserId()`), and `/login` only when there is no session at all. This also fixes the `signIn` follow-up, which navigates to Home and so inherits the same routing. The `/signup` finish button stays as the fallback. **No migration.** Tests: `confirmDestination` (attached → next, `already_claimed` → next, `email_not_verified` → `/signup`, no session → `/login?error=confirm`) in `test/auth_redirect.test.mjs`; and `member_accounts_test` asserts `claim_member_by_email` for a verified user creates the member row and is idempotent on a second call.

**Amendment 2 — a self-signup has no `profiles` row.** With amendment 1 in place, the callback's `claim_member_by_email` then failed on hosted with `members_user_id_fkey`: `members.user_id` references `profiles`, and **nothing created a `profiles` row for a self-signup** — the invite path (`claim_member_account`) inserts one, `claim_member_by_email` never did, and there is no trigger on `auth.users`. So the member link/insert (both set `user_id = auth.uid()`) violated the FK, and every self-signup attach failed (3 confirmed users on production had no profile). Fix (migration 178, `claim_member_by_email` re-issued `create or replace`, ACL held — authenticated/service-role, **not anon**): before linking or inserting the member it does `insert into profiles (id, email, full_name) values (auth.uid(), u_email, coalesce(raw_user_meta_data->>'full_name',''))` (the name `signUp` sets) `on conflict (id) do nothing`; the member insert then takes first/last from that profile as before. **The `email_confirmed_at` gate is unchanged** — an unverified user is still `email_not_verified` and gets no profile. **Every other `user_id`→`profiles` FK is unaffected:** `notifications.user_id` is set only for staff-addressed rows (member notices carry `member_id`); `push_subscriptions` has no writer; `studio_staff` is profiled via the invite path; `member_bootstrap`/`getMemberContext` read names off `members`, not `profiles`. Test in `member_accounts_test`: a self-signup with NO profile gets one created (`full_name` from `raw_user_meta_data`), the member row inserted with the right first/last names, idempotent on a second call; an unconfirmed user is refused with no profile created.

**Amendment — login-page wayfinding (Deanna, 30 Sep).** Members and instructors sign in on the same tenant host but at different URLs (`/login`, `/instructor/login`), and neither page pointed at the other, so people landed on the wrong one. Each login now carries a small micro-text link across: the member login shows "Instructor? Sign in here" → `/instructor/login` (white 60% on a photo, `--ink-3` on the gradient), the instructor login shows "Member? Sign in here" → `/login` (`m-micro text-ink-3`). Same host, no new helper, no env, no migration; the member login's "the word Studiior never appears" rule still holds.

## 40 — Xendit is the second payment adapter (Part A: connect, one-time purchases, callbacks, reconciliation)

Decision 16 made payments provider-agnostic: `payments.provider` is `manual|stripe`, and a manual payment and a Stripe payment activate a membership, grant a pack and confirm a drop-in through the SAME `activate_purchase()`. **Stripe does not serve Philippine merchants; Reform Collective has a verified Xendit business account.** Xendit becomes provider `'xendit'`, through the same `activate_purchase()`, nothing else. **Studiior INITIATES every payment** (creating the Xendit Payment Session stamped with our own ids) and learns the outcome from Xendit's callback; it never scrapes Xendit for unexplained payments. **This is Part A — one-time purchases only. Subscriptions / monthly auto-charge are Part B, not built.**

**One-time only means non-recurring PLANS: `class_pack` and `drop_in`.** A recurring plan is a subscription (auto-charge = Part B), so its Buy button does not appear; recurring plans keep the Decision-16 "how to buy at the desk" text. The buyable products are the plans on `/account/plan` whose `type in ('class_pack','drop_in')` — each activates through `activate_purchase()` exactly as a cash pack does, so a Xendit pack and a cash pack are the same membership row, distinguished only by the `payments.provider` and `reference`.

**The Xendit facts, verified against docs.xendit.co and a live test-mode call, not guessed.** Create a session: `POST https://api.xendit.co/sessions`, HTTP Basic with the tenant's **secret key as the username** (empty password); body `reference_id` (OUR purchase id), `session_type:'PAY'`, `mode:'PAYMENT_LINK'`, `amount`, `currency:'PHP'`, **`country:'PH'` (required — the docs omit it from prose but reject without it)**, `customer`, `description`, `metadata {studio_id, member_id, kind, plan_id}`, `success_return_url`, `cancel_return_url`; the response carries `payment_session_id`, `payment_link_url`, `status`. **AMOUNT IS IN MAJOR UNITS (whole pesos), not centavos** — proven live: a session created with `amount:1500` renders as **₱1,500** on the hosted checkout (centavos would show ₱15.00). Our DB stores `amount_cents`, so `xendit_amount = amount_cents / 100` on the way out and `amount_cents = round(xendit_amount * 100)` on the way back — the one unit assumption is isolated in a single helper each side. Session status: `ACTIVE|COMPLETED|EXPIRED|CANCELED`. Get status (for reconciliation): `GET /sessions/{payment_session_id}` → `status`, `payment_id`. Callbacks: the terminal events for a PAY session are `payment.succeeded`/`payment.capture` (docs pages disagree on the name) and `payment.failure`, header **`x-callback-token`** equal to the tenant's callback verification token; the payload carries `event`, `business_id`, `created`, and `data` with `reference_id` (OUR purchase id), `payment_id` (Xendit's), `status` (`SUCCEEDED`), and `metadata`. **The webhook keys off `data.status = 'SUCCEEDED'`, not the event name**, so the name disagreement cannot break it. Test connection: `GET /balance` (Basic auth) — a harmless 200/401.

**Secrets: encrypted at rest under an env-only key, and the DB never holds plaintext.** `studio_payment_providers (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256, key_last4, test_mode, connected_at, connected_by, last_verified_at)`, PK `(studio_id, provider)`. The secret key and callback token are AES-256-GCM encrypted in the Next runtime under `INTEGRATIONS_ENCRYPTION_KEY` (32 bytes, base64, held ONLY in the Vercel env — never in the DB, never in the repo, never logged); the stored ciphertext is `v1.` + base64(iv‖authTag‖ciphertext). RLS makes the row readable **only by owner-role sessions** (`is_owner(studio_id)`), and the purchase path reaches the secret through a SECURITY DEFINER `xendit_checkout_context(studio_id)` that returns the secret ciphertext + `test_mode` to an authenticated member of that studio — **the ciphertext is useless without the env key**, which lives only in the server runtime, so this respects the no-service-role-client rule (the member's server action decrypts and calls Xendit; the browser never sees ciphertext or key). **Why a table and not Vault** (where the Stripe platform secret lives): these are PER-TENANT secrets, one row per studio, connected and rotated by the studio owner through the app — Vault is a platform-wide store with no per-tenant CRUD or RLS. **What it costs:** ciphertext sits in a queryable table; the mitigation is that it is AES-GCM under a key the DB does not have and RLS is owner-only, so a full table read yields nothing usable.

**The callback token is stored BOTH as ciphertext AND as a sha256 hash, and the hash is the load-bearing one.** `xendit_webhook` is granted `anon` (a callback carries no session) — so, exactly like `stripe_webhook`, the credential must be verified INSIDE the function in SQL, or the anon RPC would be an unauthenticated "activate this purchase" surface that the Next route's own token check cannot protect (anyone can call the RPC directly, bypassing the route). Stripe verifies an HMAC in SQL against a Vault secret; Xendit's token is per-tenant and encrypted under an env key the DB cannot read, so the webhook instead verifies `encode(digest(p_token,'sha256'),'hex') = callback_token_sha256` for the studio resolved from the payload's `reference_id`. The ciphertext is kept for parity/rotation; the hash is what gates activation. **The route is a thin pass-through**: it hands the raw payload and the `x-callback-token` header to `xendit_webhook(p_event jsonb, p_token text)` and maps `PT401`→401; all tenant resolution and token verification happen in SQL. This is the `stripe_webhook` shape faithfully — the credential is an argument, checked in the function.

**`xendit_webhook` is the TWELFTH pre-login surface.** It is SECURITY DEFINER, granted anon, and guards inside: resolve the purchase from `reference_id` (unknown → `ignored`, stores nothing); verify the token hash for that purchase's studio (mismatch → `PT401`, stores nothing); store the event idempotently (`xendit_events.event_id` unique, `on conflict do nothing` → replay is `duplicate`, no second activation); require the purchase still `pending`; on a success event require `amount` and `currency` to match the purchase when the payload carries them (mismatch → refused + logged, no activation); then call `activate_purchase(..., p_enforce_seat_cap => false)` (money already captured — never refuse a completed payment, the Stripe-checkout rule), insert the `payments` row (`provider='xendit'`, `reference` = Xendit `payment_id`), and flip the purchase to `succeeded`. A failure event flips it to `failed` and notifies the member. The canonical anon list becomes **twelve** (the eleven plus `xendit_webhook`), asserted in the migration and named in `public_schedule_test`; nothing else becomes anon.

**A pending-intent tracker, because there is no `purchases` table and `payments` is money that MOVED.** `payments` records money received (written on success, as the Stripe handler does); it has no plan/session columns and mixing a pending intent into it muddies "payments = what was actually paid". So `xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, status pending|succeeded|failed|expired|cancelled, payment_session_id, payment_link_url, xendit_payment_id, failure_reason, created_at, updated_at, completed_at)` is the intent + session tracker; its `id` is the `reference_id` we send Xendit, and it is what the member's `/purchase/{id}` poll screen reads. On success the `payments` row is written with `provider='xendit'` and `reference` = the Xendit payment id, so the existing revenue/payments screens show it with no change beyond a provider label.

**`xendit_events` is the idempotency ledger:** `(id, studio_id, event_id unique, event_type, payload, received_at, processed_at, purchase_id)`, stored only AFTER token verification, unique on `event_id` (`coalesce(data.payment_id, event.id, sha256(payload))`), so a replay is a no-op.

**Reconciliation is two pieces, because the outcome can only be learned from Xendit (env key + an HTTPS call), which a pg_cron SQL function does not have — and a cross-tenant AUTOMATIC ask-Xendit would need either a service-role client (forbidden) or a thirteenth anon secret-returning surface (forbidden by "anon is exactly twelve").** A pure SQL sweep cannot decrypt the AES-GCM secret (no env key in the DB) nor make the Basic-auth GET; and any cross-tenant function that returned secrets to a client role would be the very leak the encryption exists to prevent. So the rule-respecting realization: **(1)** a pg_cron sweep `xendit_reconcile_sweep()` (service context — the "existing sweep mechanism") marks purchases pending beyond a generous window (2 h) as `expired` and notifies the member, writing one `audit_logs` row per pass. This is safe precisely because it does NOT decide success: **the webhook activates any not-yet-`succeeded` purchase, not only a `pending` one**, so a late or retried success callback still lands (and Xendit retries webhooks on a non-2xx). **(2)** an owner-triggered **"check pending payments with Xendit"** on the settings screen: an owner session (owner-guarded) decrypts THIS studio's own key and `GET /sessions/{id}` for its pending purchases, applying `COMPLETED` via the same activation path and `EXPIRED`/`CANCELED` as a mark-and-notify. This asks Xendit where the rules allow it — owner-scoped, per-tenant — and keeps the anon surface at exactly twelve, with no service-role client and no shared cron secret. **Cost, stated:** there is no fully-automatic cross-tenant "ask Xendit" — a missed callback is caught by Xendit's own webhook retries, then by the owner's on-demand check, and only its local expiry is automatic.

**Payments UI:** the existing payments/revenue screens show `provider='xendit'` with the Xendit `payment_id` as the reference. **No Xendit-initiated refunds in Part A** — refunds stay on the existing adjustment path (`record_refund`), and the screen says so.

**The member's `has_payment_provider` stays Stripe-specific** — it gates a saved-cards screen whose language ("add a card, it is saved for next time") is untrue of Xendit's hosted checkout, so overloading it would mislabel that screen. Instead `member_bootstrap` gains a separate `xendit_enabled` flag (a connected `'xendit'` provider row exists), and `/account/plan` shows Buy on one-time plans (`class_pack`/`drop_in`) only when it is true; a studio with no provider still shows the unchanged "how to buy" text.

**Amendment — expired is not final.** The local reconcile sweep marks a purchase `expired` after a generous window, but the member may have paid: a local timeout cannot be the last word. The activation path already honoured this — `xendit_activate_success_internal` skips only an already-`succeeded` purchase, so both `xendit_webhook` (a later `payment.succeeded`) and `xendit_apply_session` (the owner's "check with Xendit" reporting `COMPLETED`) activate an `expired` purchase, with the amount/currency checks unchanged. What was missing was a **trace**: `xendit_activate_success_internal` is re-issued (migration 177, `create or replace`, ACL held — service-role only, anon stays EXACTLY TWELVE) to write an `audit_logs` row **`xendit.expiry_overridden`** (carrying `prior_status` and the Xendit `payment_id`) whenever the purchase it activates was `expired`, so a paid-after-timeout activation is auditable. A replay is still a no-op (the event idempotency and the `succeeded` short-circuit both hold). Test in `test/xendit_test.sql`: mark a purchase `expired`, deliver a `payment.succeeded` → the membership/pack activates and an `xendit.expiry_overridden` audit row is written; a replay returns `duplicate` with no second activation.

**Amendment 2 — the callback must never 500 on a sample payload.** Xendit's "Test and save" on the Webhooks page posts a sample `payment.succeeded` whose `reference_id` is NOT a UUID (`a5151a05-…-1ref3e7fb3a`, currency IDR, `business_id` `sample_business_id`), with a valid `x-callback-token`. `xendit_webhook` resolved the purchase by casting `reference_id::uuid` BEFORE verifying the token, so the cast raised `22P02` and the route returned **500 with the raw Postgres message** — Xendit then refuses to save the URL. Fix (migration 179, `create or replace`, ACL held — anon stays EXACTLY TWELVE): **verify the token FIRST by the studio that OWNS it** (`callback_token_sha256` → studio; the token is the per-studio credential), THEN validate `reference_id` against the UUID regex before casting. A bad reference, an unknown purchase, or a purchase belonging to a **different** studio than the token matched (cross-tenant) is stored in `xendit_events` (marked processed, with the reason) and returned as `{result:'ignored'}` — **never raised**; only a token matching no connected studio raises `PT401`. The return key became `result` (was `status`). **The Next route** maps `ignored`/`duplicate`/`processed`/`refused` (no error) → 200, `PT401` → 401, and anything else → 500 with a **generic** `{"error":"callback failed"}` (the real error only in the server logs — never echo a database message to the caller). Tests: the exact hosted sample with a valid token → 200 `{result:'ignored'}`, event stored, nothing activated; a valid reference to ANOTHER studio's purchase with this studio's token → `cross_tenant` ignored, not activated (teeth); wrong token → 401; the succeeded/duplicate/mismatch cases unchanged. Verified live: the exact sample through the route returns 200 (not 500).

**Amendment 3 — the `customer` object needs `reference_id`, and the dedupe key needs the event type.** Two fixes. **(a)** Tapping Buy failed with *"customer must have required property 'reference_id'"*: Xendit's `POST /sessions` requires the `customer` object to carry `type` + `reference_id` + `individual_detail` (verified against docs.xendit.co — `customer.required = [type, reference_id, individual_detail]`, and `reference_id` must be **alphanumeric with no special characters**). `lib/xendit.ts` `buildSessionBody` (extracted pure, so it is unit-testable) now sends `customer = { reference_id: <member id with hyphens stripped>, type: 'INDIVIDUAL', email, individual_detail: { given_names, surname } }`; the buy action reads the member's `first_name`/`last_name`/`email` (own-row RLS) for it. **The whole session request is a client-side call, exercised only against Xendit** (there is no JS suite for `lib/xendit.ts`); it is verified LIVE against Reform's test account — the real `buildSessionBody` output returns **201**, and a compiled unit assertion confirms the shape (hyphen-stripped `reference_id`, `individual_detail.given_names`/`surname`, no customer when the ids are absent). **(b)** The event idempotency key was the payment id alone, so a `payment.failure` and a later `payment.succeeded` for the same payment id would collide as a "duplicate" and the success would never activate. Migration 180 re-issues `xendit_webhook` (`create or replace`, ACL held, anon stays TWELVE) so the `event_id` is `<event_type>:<payment_id-or-id-or-hash>` — the two are now distinct events. Test in `test/xendit_test.sql`: a `payment.failure` then a `payment.succeeded` for the SAME payment id → both processed (two stored events), the success not a duplicate.

**Amendment 4 — resolve the purchase robustly (Xendit appends a suffix to the payment's `reference_id`).** A real hosted purchase (PHP 8,500 pack) succeeded at Xendit but the app stayed on "Confirming your payment…": Xendit's PAYMENT object carries `reference_id = <our session reference_id>_<suffix>`, so the UUID-regex check filed the callback as `bad_reference` and ignored it. Fix (migration 181): the callback resolves the purchase in order via a shared `xendit_resolve_purchase(data)` — **(1)** `data.metadata.purchase_id` (now stamped into the session metadata on creation — the authoritative path), **(2)** `data.payment_session_id` matched to the session id stored on the purchase, **(3)** `reference_id` with any `_suffix` stripped and validated as a UUID; only if all three fail is it `bad_reference`. Token-first order and the cross-tenant check (the resolved purchase's studio must match the token's) are kept; amount/currency unchanged. **Recovery for a callback filed before the fix:** `xendit_reprocess_ignored(studio)` (manager-up) re-runs the resolution on the studio's STORED ignored events and activates any that now resolve to a pending success (idempotent); it is folded into the settings **"Check pending payments with Xendit"** action, which also GETs each pending purchase's session status and activates a `COMPLETED` one. **For the member's specific stuck purchase, the recovery is that button** — its session is `COMPLETED` at Xendit, so the session-status GET activates the pack even though no resolvable callback event was stored. The **"Confirming your payment…"** screen already gives up after 2 minutes with "we'll email you" (a 120s poll cap), so it does not spin forever. `test/xendit_test.sql` grows to 59: a `<uuid>_SUFFIX` reference activates; a bad `reference_id` with `metadata.purchase_id` activates; a stored ignored event reprocesses to activate a pending purchase and is idempotent; a non-manager is refused `xendit_reprocess_ignored` (PT403); the sample still returns `ignored`. Verified on hosted read-only that the only stored events were the two "Test and save" samples (`bad_reference`) — the member's real callback was never stored, which is why the session-status recovery (not a stored-event replay) is what activates her purchase.

**Amendment 6 — reuse the Xendit customer, don't recreate it.** (Labelled "amendment 5" in the request, but 5 was `payment_session.completed`.) A member's SECOND checkout failed 409 *"customer: The reference_id entered has been used before"* — the first checkout created a Xendit customer with `reference_id` = our member id, and Xendit refuses to create it again. Verified live: a customer object with a fresh `reference_id` → 201 + `customer_id`; a second session with `customer_id` (no customer object) → 201; a third with the same `reference_id` in a customer object → 409; `GET /customers?reference_id=…` → the existing id. Fix (migration 183): a small `member_payment_customers (studio_id, member_id, provider, customer_ref)` table (a table, not a column on `members`, so `guard_member_self_update` is untouched and a second provider slots in later), RLS member-self-read + desk-up-staff-read, written by the SECURITY DEFINER `xendit_set_customer` (guarded to the member). On checkout the buy action reads the stored `customer_ref`: present → send `customer_id` (no customer object); absent → send the customer object and, on the 201, store `data.customer_id`. If Xendit still reports the `reference_id` used (the id was lost — the pre-fix state), it looks the customer up via `getCustomerByReferenceId` (`GET /customers?reference_id=<stripped member id>`), stores it, and retries the session once with `customer_id`. `buildSessionBody` sends `customer_id` XOR the customer object. Tests: `xendit_set_customer` stores + upserts, a member sees only their own row (not another studio's), desk-up staff see their studio's, a non-member is refused PT403; the `buildSessionBody` branches are asserted (compiled). Verified live: two sessions for the same member → both 201.

## 39 — Instructor class reminders (their week ahead, and the evening before)

An instructor with a login should get their schedule pushed to them, not have to open the app — the same courtesy the member app gives. **Per-tenant, opt-in, OFF by default** (`studio_settings.instructor_class_reminders`), Settings → Instructors under booking alerts; Reform turns it on. Two emails, in **studio time**, through the existing notifications pipeline and templates, **only to instructors WITH A LOGIN**, **published months only**, **scheduled occurrences only**:

1. **Weekly digest — Sunday 18:00 studio time.** *"Your classes this week"*, Monday to Sunday, grouped by day, each line: time, class type, room, headcount/capacity, plus the add-to-calendar/feed link that already exists (Decision 33). **Skipped when the instructor has no classes that week.**
2. **Evening-before reminder — 19:00 studio time.** Tomorrow's classes for that instructor, same line format. **Skipped when none.**

**Dedupe key per instructor per digest per date**, so a re-run never sends twice. Scheduling via the **existing sweep/cron mechanism** the booking alerts use (a 15-minute sweep that checks each studio's local clock and fires once past the threshold, the dedupe making it idempotent); a durable **`audit_logs` row per pass**. A class **cancelled after** the email is not re-sent — the booking-alert precedent already accepts this (the calendar feed is the live channel). Not anon; the anon surface stays **exactly eleven**. No new enum values.

**Recorded before code**, in the family of Decisions 33/38 (per-tenant instructor communication switches, off by default).

---

## 38 — Instructors confirm the classes the studio assigns them (assigned is not agreed)

The owner builds the timetable and assigns instructors to classes. Today that assignment is **silent to the instructor** — a class lands on their week with no ask, and the studio has no signal whether the person who is meant to teach it has even seen it. **Assigned is not agreed.** The instructor should be able to see what they have been given, **confirm** it, or **hand it back** — in the app, with an email nudge — **without the owner's assignment ever being blocked or undone by the instructor's silence.** Silence changes nothing: the class stays on the timetable, assigned, unconfirmed.

**Per-tenant, opt-in, OFF by default** (`studio_settings.assignment_confirmations`), so a studio that never turns it on sees no trace (the `all_off` canary proves it). Reform turns it on in Settings → Instructors, beside booking alerts, help text *"Instructors are asked to confirm classes you assign them. Unconfirmed classes stay on the timetable."*

**A request is recorded, not a state machine.** `class_occurrences` gains `assignment_requested_at` and `assignment_confirmed_at` (both timestamptz, null = never asked / not confirmed). A request is stamped whenever an occurrence **becomes assigned to an instructor who has a login** while the setting is ON — through **any** path (series materialisation, one-off create, move/reassign, engine assignment), because it is a **trigger on `class_occurrences`** (the "a booking is made from four places" lesson), not a call bolted onto each writer. **Reassignment to a different instructor clears both and re-requests** for the new person; **unassigning clears both**. Classes assigned **before** the setting turned on are **not** retroactively requested — the trigger only fires on the assignment event; the series page carries an explicit **"Ask {instructor} to confirm"** action that requests all future unconfirmed occurrences of that series.

**One email per instructor per day, coalesced**, through the existing notifications pipeline and the coalescing pattern Decision 33's booking alerts use (a per-instructor-per-day dedupe key, the pending list recomputed into the payload, scheduled for the end of the studio-local day so the day's assignments arrive as one digest), listing the classes **grouped by series** (*"Every Mon 07:00 Reformer Flow — 8 classes, 9 Nov to 20 Dec"*) with a link to My schedule. **Published months only**, same as booking alerts (an instructor cannot see a draft month, so it is not emailed about one; the request timestamp is still recorded, and the in-app ask appears when the month publishes). **No reminders, no deadline, no auto-unassign** — silence is a permanent, harmless state. A per-tenant deadline and reminders are **deferred**.

**Confirm and decline.** The instructor's My schedule gains a **"Needs your confirmation"** section at the top — future occurrences assigned to them, requested, not yet confirmed, grouped by series, with **"Confirm all"** and per-class **"Confirm"** / **"Can't make it."** `confirm_assignment(occurrence)` (SECURITY DEFINER, guarded to the **assigned** instructor) stamps `assignment_confirmed_at`.

**"Can't make it" = a cover request, per Decision 18, unchanged.** An instructor never releases a class themselves. "Can't make it" calls the **existing `withdraw_from_shift()`**: it raises a **cover request**, the owner/managers get the **existing cover notification**, and the class **stays assigned to the instructor** until someone covers it — it never becomes open by itself. Nothing about the confirmation state changes on decline: the class stays **requested-and-unconfirmed** until it is covered or confirmed. There is **no `decline_assignment` function** and no Decision 18 amendment.

**Owner-side state, never a blocker.** The roster and the schedule calendar show a small state on assigned classes — a confirmed tick, "awaiting" when requested and unconfirmed, nothing when never asked. The series page shows **"6 of 8 confirmed."** None of it gates or reverses the assignment.

**RLS and boundaries.** An instructor sees and confirms only their **own** requested classes; front desk cannot confirm or decline on anyone's behalf (the confirm/decline guards key on `auth_instructor_id` = the occurrence's instructor). Not anon; the anon surface stays **exactly eleven**. No new enum values.

**Recorded before code.** Decision 18 is **unchanged** — an instructor never releases a class themselves — and this adds a new per-tenant switch in the family of Decisions 24/25/33.

### Amendment — the "already confirmed" bypass (paper-first studios)

Studios usually agree the month with instructors **on paper first**, so asking again in the app is the exception, not the rule. When `assignment_confirmations` is ON and an instructor is selected, the calendar create form (one-off **and** repeating) and `/series/new` show a tick **"Already confirmed with {instructor} — don't ask them", DEFAULT TICKED**. Ticked → every occurrence created is stamped `assignment_requested_at = now()` **and** `assignment_confirmed_at = now()` **and** a new column `assignment_confirmed_by` (uuid, the staff user; **null when the instructor confirmed themselves**), so it reads as confirmed everywhere and **never enters the request digest**. Unticked → today's behaviour (request stamped, digest queued). The series page gains **"Mark all confirmed"** beside "Ask {instructor} to confirm" — the same stamping, for series created before this. Roster/schedule chips are unchanged (confirmed is confirmed); the **series page summary splits "confirmed by studio" vs "confirmed by instructor"** (by whether `assignment_confirmed_by` is set). **Reassignment to another instructor clears all three stamps and re-requests**, as before. When the setting is **OFF** the tick is hidden and nothing is stamped. The mechanism is one manager-up writer (`mark_series_confirmed` / `mark_assignment_confirmed`) that stamps and then **re-runs the digest queue, which cancels the now-empty scheduled digest** rather than sending a "please confirm" for classes already confirmed.

---

## 37 — A class OR a repeating series is created from any empty slot on the Schedule calendar, all three views

Migration 089 gave the calendar click-to-create, but **one-off only**, on **Day view alone**, and the form said in words "Repeating classes live in Recurring" — the deliberate narrowing recorded in migration 089's notes: "a calendar that silently created a year of classes from one click would be a bad surprise; recurring belongs at /series where the whole rule is visible." **Deanna has overridden that narrowing for the tenant.** The studio should be able to click any date/time on **Day, Week or Month** and create **either a single class or a weekly series** without leaving the calendar — provided the whole rule stays **visible inside the form** so nothing is hidden (which is the concern 089 raised, answered rather than dismissed: the surprise came from hiding the repeat, not from allowing it).

**The form is one unified create panel.** Fields, in order: class type; an instructor dropdown (active instructors + "Unassigned", defaulted to the clicked column on Day, **required to choose** on Week/Month where there is no column); the guarantee tier via the existing `TierField` (shown only when the studio has guarantees/flex on, as today); date and start time prefilled from the click — **Month has no time**, so the time field is editable and **required** there; duration/capacity as today; a **"Repeats weekly" toggle, OFF by default**. When ON: a days-of-week multi-select defaulted to the clicked weekday, and an **"Until" date, required, after the start**. A **live summary** reads back the whole rule — *"Every Mon and Thu 07:00 with Rhon until 20 Dec — 24 classes"* — so a studio sees exactly what one press will make.

**Server — no second series creator, no new SQL.** A one-off goes through the **unchanged** `create_occurrence()` path (migration 089's gate, the same one `move_occurrence` uses). A repeating class goes through **the same mechanism `/series/new` uses** — the `class_series` INSERT whose 057 trigger materialises twelve months and 061 assigns — with `rrule = FREQ=WEEKLY;BYDAY=…`, `starts_on` = the clicked date, `ends_on` = the Until date, and the tier applied through the existing `set_series_guarantee()` (the canonical per-series tier writer, which `/series` already uses on the detail page). The series **name is derived from the class type**, as the one-off's occurrence name is. The insert and its validation are **extracted and shared** with `createSeries` rather than duplicated. The blocks the series mechanism surfaces are surfaced in the form as the one-off's are (RLS → owners/managers only, a rule the parser refuses → PT422, no location, and the form requiring a room when the studio has more than one); the per-week room/instructor clashes are handled by the generator exactly as `/series/new` handles them (the weeks that clash are skipped, `generate_occurrences` being revoked from clients so there is no client path to report them per-week — the same behaviour `/series/new` has always had). On success the panel shows any warnings (the `standalone_flex` heads-up from `set_series_guarantee`) and a **"View series"** link to `/series/{id}`.

**Calendar — slot selection on all three views.** `onSelectSlot` was gated `if (view !== "day") return` because instructor columns (resources) exist only on Day. It is enabled for Week (start/end wall time, no resource → the instructor is chosen in the form) and Month (a date only → the time is entered in the form).

**The instructor-column default gains a visible toggle.** Day view hides instructors not teaching that day (a column per instructor does not scale — the migration-that-added-columns lesson), switchable today only through a "Showing the N…" text link. That default stays, but a visible **"Teaching today / Everyone"** toggle joins the toolbar beside the instructor filter, carried in the URL (`?all=1`) like the filter, so it survives navigation.

**Recorded before code, per this project's rule.** No decision-log entry contradicts this; it amends migration 089's stated narrowing, and 089's own reason (keep the whole rule visible) is honoured by the form rather than by forbidding the feature.

### Amendment (c) — a series assigned to an instructor warns on weeks outside their agreed dates, and blocks nothing

A one-off `create_occurrence()` **hard-blocks** an instructor outside their agreed availability dates (`instructor_valid_on` false → `outside_availability_dates`); the series-materialise path (the 057 trigger's `generate_occurrences`) does **not** consult `instructor_valid_on` at all, so a repeating series assigned to an instructor is created whatever their stated dates. Rather than teach the generator to block (which would refuse weeks and complicate building a month before anyone has submitted dates), a series **keeps every week assigned** and **warns**: both create paths (the calendar slot-create and `/series/new`) surface *"3 weeks are outside Rhon's agreed dates."* alongside the existing skipped-weeks warning. **No block, no diversion to open shifts** — the studio built it deliberately and is simply told. The count is the future scheduled occurrences of the series whose assigned instructor is not `valid_on` their local date; with **no availability rows** (the state of every Reform instructor today) `instructor_valid_on` is true everywhere, so there is **no warning** — the warning only appears once an instructor has submitted a month that excludes these weeks. **The one-off's hard `outside_availability_dates` block is to be revisited** once real instructors are submitting months (it may want to become a warning too, for consistency); recorded, not changed here.

---

## 36 — The member app's booking horizon is the MEMBER's, resolved exactly as book_class rule 2.1.2 does (amendment to the booking-window rule)

Business rule **§2.1.2** has always said the booking window is the member's **highest-priority usable membership's plan window**, falling back to `studio_settings.booking_window_days` — "a plan-level override wins over the studio default." `book_class()` implements it: it reads `membership_plans.booking_window_days` from the member's highest-priority usable plan (recurring > trial > pack, earliest expiry; the row also carrying the daily cap) and coalesces to the studio value. **The member app never learned this rule.** `member_bootstrap` (migration `20260831680000`) exposed only `coalesce(studio_settings.booking_window_days, 30)` — the studio value alone — and `lib/member.ts` / `app/member/book/page.tsx` built "Opens for booking …", "Classes start …" and the class-detail gate from it. So a member on a **60-day plan** at a studio whose row still holds the onboarding default of **30** saw "Opens for booking Saturday 10 October" for a 9 November class that `book_class` would have **accepted**. **The screen and the rule disagreed, and the rule is right** — a member turned away from a class they could book is the worst version of this bug.

**The fix makes divergence impossible rather than copying the rule into TypeScript.** The §2.1.2 resolution is extracted into one function, **`member_booking_window_days(p_member_id)`** — SECURITY DEFINER, guarded so the caller must be the member, staff of that studio (`is_desk_up`), or a trusted backend role (`is_service_context()`), never anon; it replicates book_class's **exact** row selection (the same `booking_window_days IS NOT NULL OR max_bookings_per_day IS NOT NULL` filter and priority order, so it picks the same plan book_class does) and coalesces to the studio value. `book_class` is re-issued to **call it** for the window (keeping its own read of the same row for the daily cap; behaviour identical, the existing suites prove it), and `member_bootstrap` resolves `booking_window_days` **through the same function**. One definition of the horizon, read by the rule and the screen alike — a second implementation would have agreed exactly once. The guard mirrors book_class's own permission (`is_service_context() OR is_desk_up OR is_self`) precisely, so calling it inside book_class can never refuse a booking book_class would allow.

**The client stops inventing 30.** `lib/member.ts` and the book page use the server-resolved value for all three surfaces; the `?? 30` fallback is gone. If the value is null (a studio with no setting AND no plan window), the screen does **not** substitute 30 — it fails loudly in dev, because a made-up horizon is the bug in a quieter form.

**Second gap, closed here: `studio_settings.booking_window_days` had no settings UI.** Its only writer was the onboarding wizard (`app/staff/onboarding-actions.ts`), so a studio could never change it after setup — the twenty-six-columns-without-UI trap again. Settings → Timetable gains **"How far ahead members can book"** (days), writing the column, with the help text **"A membership plan's own window overrides this."** so an owner understands the plan takes precedence. `scripts/audit-settings-ui.py` stops listing the column.

**Recorded before code, per this project's rule.** Migration `20260831760000`; teeth in `series`/`book_class`/`member_app` scope — the standing assertion is that `member_bootstrap.booking_window_days` equals what `book_class` used for the same member, and it fails if either side is changed to read the studio value directly.

---

## 35 — Check-in at the door: member self check-in with a geofence, a printed studio QR, and instructor scanning

Today check-in is a rotating code a member holds up and a desk **types back** (`resolve_checkin_code` verifies identity only, is desk-up, and the occurrence comes from the roster the operator is standing on; the instructor roster inserts `check_ins` directly as `'staff'`). Decision 35 moves the act to the door: a member checks themselves in **from their phone**, a printed studio QR opens the same flow, and an instructor **scans**. This replaces the kiosk-first idea — a shared tablet is deferred (§6 below).

**This amends Permissions §8 note 13**, which reads "Self check-in by presenting a rotating QR code, scanned at the desk." It now reads: a member may check themselves in from their phone, inside the window, when they are at the studio. The §8 table's Mem ⚠¹³ stays ⚠ (still conditional — window, location, waiver), and the amendment is written in the same breath as the migration, per this project's rule about a doc that disagrees with itself.

**1. Member self check-in, phone-first.** Inside the §8 window (`checkin_opens_minutes_before` / `checkin_closes_minutes_after` — the existing per-studio settings, migration 007; Reform to set 30/…), the Home "next class" card gains a **Check in** button. It calls a new **`self_check_in(p_booking_id, p_lat, p_lng, p_accuracy_m)`** — SECURITY DEFINER, guarded on: the booking being the **caller's own** (via `members.user_id = auth.uid()`, the `coalesce(...)` null-safe idiom, PT403 otherwise), the **window open**, the class **scheduled** and in a **published month** (Decision 25), the **waiver signed on the current required version** (the member gate at the door — see the flag below), and the **geofence** (§2). It writes `check_ins` with **`method = 'self'`**, `checked_in_by =` the member's own profile, and the **distance and accuracy** on the row — **never the coordinates** (§3/privacy: the lat/lng compute the distance and are then discarded). **It is SECURITY DEFINER precisely so no member INSERT policy is added to `check_ins`** — the existing invariant ("`check_ins` has no member insert policy and should not gain one") stands; a guarded function writes as its owner, the member never inserts directly. **Idempotent:** a second call for the same booking (the `check_ins.booking_id` unique index → 23505) returns the same `You're checked in` result, not an error. **Occurrence selection is a non-problem here:** the button is **per booking**, so a member with two bookings in overlapping windows sees **two cards** and taps the right one — nothing is guessed, which is the ambiguity a kiosk-with-a-bare-code would have had.

**2. The geofence — and it goes on `locations`, not `studios`.** `locations` is **not** dormant: every room, series and occurrence carries a `location_id`, and the seed creates a primary location. A geofence is a property of a **physical place**, so `latitude`, `longitude`, `self_checkin_radius_m` (default 200), `self_checkin_accuracy_cap_m` (default 150) and `self_checkin_requires_location` (boolean, default true) go on `locations`, and the check is against the **occurrence's own location** (`class_occurrences.location_id`), which is future-proof for multi-location and correct for a studio with two rooms across town. **The reported accuracy is added to the radius, but CAPPED first — because accuracy is client-supplied, and without a cap a phone reporting `±5000 m` would pass from anywhere.** So `self_check_in` refuses **PT422** with `reason`: `low_accuracy` when `accuracy_m` exceeds `self_checkin_accuracy_cap_m` (*"Your phone can't place you closely enough — try again outside, or show your code at the desk"*); `too_far` when `distance > radius + min(accuracy_m, accuracy_cap_m)`; `no_location` when the location requires it and none was supplied; and `studio_has_no_location` when the occurrence's location has no coordinates. The `low_accuracy` check runs first, so a phone reporting 4000 m at distance 50 m is **refused `low_accuracy`, not passed** — the cap is the whole point. The member screen requests browser geolocation **on the button press**, sends whatever it gets, and renders the reason as a sentence — *"You need to be at the studio to check in — or show your code at the desk."*

**Browser location can be faked, and this is a convenience gate, not a security boundary — stated plainly.** The only incentive to cheat is dodging a no-show mark; **pay is unaffected** (Decision 32: pay is from bookings, `greatest(booked_at_cutoff, booked_at_start)`, never attendance), self check-ins are **marked on the roster**, and the desk can **correct a self check-in to no_show** exactly as today. A studio that turns `self_checkin_requires_location` **off** has made both the phone button and the printed QR a **trust-based** check-in, and the settings copy says so.

**Staff UI:** Settings → Studio gets, for the primary location, a **coordinates** field, the **radius**, the **accuracy cap** (editable beside the radius), and the **require-location** switch. **No paid geocoding key**, so this is **lat/lng inputs** with an "**open in Google Maps to verify**" link (prefilled from the stored address where there is one) rather than an embedded map/pin — feasible with nothing bought, and honest about it.

**3. The printed studio QR.** Settings → Studio → **"Print check-in code"**: a per-studio **static** slug (`encode(gen_random_bytes(...),'hex')`, re-mintable — re-minting kills the old printout), rendered as a QR encoding **`{member_app}/checkin/{slug}`** — **a URL that opens the member app**, not a credential. Scanning it opens a screen that runs the **same** `self_check_in` (window + geofence + waiver) for the member's open booking at that studio. Signed-out → login, then return to the same screen. It is a **shortcut, not an identity**: it says which studio, the member's session says who; with `require_location` off it is trust-based (above). **Do not confuse the two QR codes:** the **member's personal** QR keeps encoding the **8-char rotating code** (scanned BY staff/instructor, §4); the **printed studio** QR encodes a **URL** (scanned BY the member's own camera to open the app).

**4. Instructor scanning.** A new **`instructor_resolve_code(p_occurrence_id, p_code)`** — guarded on `auth_instructor_id(studio) =` the occurrence's instructor **AND** the window open — returns the member **only if booked in THAT occurrence** (the roster context supplies the class, as it does for the desk). The roster **CheckIn writes `method = 'instructor'`** — a **new `checkin_method` enum value**, which needs its **own migration first** (a new enum value cannot be used in the transaction that adds it — the recorded enum trap). In the same enum migration, **the importer switches from `'staff'` to `'import'`** (also a new value) so that `'staff'` finally means *a human at the desk* — existing imported rows keep `'staff'` (historical; the change is not retroactive, noted so nobody reads old imports as desk check-ins). Camera scan on the roster uses **`BarcodeDetector` with a jsQR fallback**, and the **typed-code box stays as the always-works path** (a camera that will not focus in a dark studio is a real thing). The member's personal QR keeps encoding the 8-char code, so one code serves both the desk and the instructor scanner.

**5. Roster and records.** The staff and instructor rosters show the **method per checked-in member** (self / scanned / desk) and, **for self, the distance** — the stored `distance_m`. The raw lat/lng are **never stored** (they compute the distance in `self_check_in` and are discarded); only `distance_m` and `accuracy_m` persist on `check_ins`. The desk can correct a self check-in to `no_show` as today. **Reports are unchanged** — a check-in is a check-in whoever made it, and pay never read attendance anyway.

**6. Kiosk role — DEFERRED, not in this decision.** A shared tablet at the counter is a possible later addition: a sixth role, contained by auditing every `auth_staff_studios()`-scoped policy (a plain staff row inherits every staff read, which is the real work), and `resolve_checkin_code`'s desk-up guard widened or a new function. Recorded here so it is a deliberate later choice, not a forgotten one.

**7. Off by default by EXISTENCE, no switch.** Self check-in is on when the occurrence's location **has coordinates**. With no coordinates and `require_location` on, the Home button is **absent** and the printed QR screen says "check in at the desk" — the challenge/announcement optional-by-existence pattern. **The `all_off` canary is unchanged:** its studio sets no coordinates, so the new columns default null, nothing is self-checkable, and no sweep or trace appears — asserted as absence, not a new zero.

**Contradictions and tensions flagged (per the brief):**

- **The member waiver-at-the-door applies at EVERY door — decided (b).** Decision 34 put the member re-sign check at **booking** (`book_class` 2.1.4) and the *guest* re-sign check at the **door** (`enforce_guest_waiver`, scoped to the `guest_passes` join). Decision 35 extends `enforce_guest_waiver` so a **member** whose signature is **missing or on an older required version** is refused at **self check-in, at the desk, AND by an instructor scan** — `enforce_guest_waiver`'s trigger fires on **every** `check_ins` insert, so all three doors are covered by one rule. The refusal is **PT422 `waiver_not_signed`** (reusing the booking-gate reason, not a new code), with the sentence pointing at **their phone** (*"Please sign the studio waiver in the app before checking in"*); the desk's **paper path (`record_document`) stays as the fallback**, confirming the signature and clearing the gate exactly as it does for a guest. This is a change from today, where a member is gated only at booking — a member whose studio just turned on `require_waiver` + `requires_resign` with existing bookings is now stopped at every door until they sign. `self_check_in` also checks the waiver itself (belt-and-braces) so the sentence is clean rather than a raw trigger error.

- **§14 and the coordinates — the raw lat/lng are never stored.** §14 keeps a member's contact details and address with the office. The coordinates are used **only to compute `distance_m` inside `self_check_in` and are then discarded**; `check_ins` persists `distance_m` and `accuracy_m` and nothing more. A check-in **distance** ("40 m") is an operational fact about this check-in, not a location trail, so surfacing it to the instructor on the roster is fine and breaches nothing — there is no raw coordinate for the roster reader to leak.

- **"Instructor check-in" already means something else (Decision 28).** Decision 28's instructor check-in is the instructor confirming **their own** attendance for **pay** (`instructor_confirm_class`, a held pay record). Decision 35's instructor scanning is the instructor recording a **member's** attendance (`check_ins`). Different tables, different purpose, no collision — flagged so the two are not conflated in code or copy.

- **The window trigger still fires.** `check_ins_window` (before insert, migration 007) and the extended waiver trigger fire on **every** insert including `self_check_in`'s, so the function's own window/waiver guards are belt-and-braces (and give better sentences); a self check-in outside the window is refused either way.

**Where:** Permissions §8 (amended) and §14; Business Rules §8; Data Model §5 (`locations`, `check_ins`); Decisions 25 (published month), 28 (distinct), 32 (pay unaffected), 34 (waiver at the door). **Status:** entry written, build not started. **Build in two halves, each through the full loop.** (A) the enum migration (`'instructor'`, `'import'`); `locations` coordinates + radius + accuracy cap + switch + the Settings UI; `self_check_in` with geofence (capped accuracy) + window + member waiver-at-door (every door); the Home card button + reasons as sentences; `distance_m` + `accuracy_m` on `check_ins` (never coordinates); roster method + distance display; tests (own booking only; window closed → refused; too far → `too_far` with capped accuracy honoured; accuracy 4000 at distance 50 → `low_accuracy` not a pass; no location → `no_location`; studio without location → button absent; waiver missing/stale → PT422 `waiver_not_signed` at self/desk/instructor; idempotent; another member's booking → PT403; `all_off` unchanged); browser-verify at phone width with mocked geolocation inside and outside the radius. (B) the printed studio QR (slug, print view, re-mint) + the `/checkin/{slug}` route; `instructor_resolve_code` + camera scan on the roster + `method = 'instructor'`; tests; full loop.

---

## 34 — The waiver is a real, versioned, signed document

Until now "signed the waiver" meant a bare `members.waiver_signed_at` timestamp: the studio could not supply waiver text (the `studio_settings.waiver_text` column was never read or written), the member was shown nothing before tapping "Sign the waiver", and nothing recorded what was agreed. Decision 34 makes the waiver a document a studio provides, a member reads and signs, and the product stores as a signed PDF.

**Source, in Settings → Member features, text OR PDF, versioned and immutable.** A studio provides its waiver as rendered **text** or an uploaded **PDF** (the `studio-branding` bucket pattern, size-capped like the login image). A new `waiver_versions` table holds each version (studio, format, body-or-storage-path, **content hash**, created_by, created_at, `requires_resign`). **A new version supersedes; it never edits** — the old version is retained because signatures point at it. The dead `studio_settings.waiver_text` column is abandoned in favour of this table (not read again).

**Signing: phone-first, full content, reach-the-end, drawn signature.** The member signs the **current** version on a screen that shows the whole thing — text rendered natively, a PDF rendered page by page — and the Sign action is disabled until they reach the end. The signature is **drawn on a canvas** (finger or stylus). **The member's name is pre-filled from their member row (`first_name + last_name`) and is not editable on that screen** — the signature is tied to the person the studio knows, not to client input. Recorded in a `waiver_signatures` row: version id, content hash (copied from the version, not recomputed client-side), the signature image path, the pre-filled name, `signed_at`, the member's `user_id`, the user agent, and — **best-effort where the request headers carry it — the request IP** (a null is fine; it is provenance, not a gate).

**The product produces the signed document.** A **server-side Next route/action, running with the member's own session** (no service-role client — that rule stands), composes the waiver content with a **signature block appended at the end** — signature image, the pre-filled name, date/time in the studio's zone, and the version id + content hash — renders it to a **PDF**, uploads it to the member's private `member-documents` folder, and records it as a `'waiver'` document so `members.waiver_signed_at` is set exactly as the paper path sets it and staff see it on the member's documents like any other. **The signature PNG is stored in the member's own `member-documents` folder beside the signed PDF; `waiver_signatures` keeps the object path, never the image bytes.** **There is no field-placement editor: the signature block is always appended at the end.** Because every current write path to `member-documents` is desk-only, Decision 34 adds (a) a **member-self storage INSERT policy** scoped to the member's own id (`foldername[2]`, the `member-avatars` owner-write shape) and (b) a `SECURITY DEFINER` self-sign function that inserts the document row and the signature row and sets `waiver_signed_at` under RLS as the owner — `record_document` stays the desk/paper path, unchanged, and records the version too.

**The gate is unchanged, plus re-sign — and re-sign lives in rule 2.1.4.** `require_waiver` still gates booking through `members.waiver_signed_at`, but the check in **`book_class` rule 2.1.4** now treats a member whose signature is on an **older required version** as unsigned: it compares the member's latest `waiver_signatures.version_id` against the studio's current required version, and a mismatch (when that current version is marked `requires_resign`) fails the gate, `waiver_signed_at` no longer satisfies it, and the Home banner reappears. **The same check goes in `enforce_guest_waiver` at check-in**, so a guest on a stale required version is turned away at the door exactly as an unsigned one is. A new version **without** `requires_resign` leaves existing signatures standing. **`book_class` is rebuilt from migration 163's file** (the free-first belt version) — and, because it has been re-issued from the wrong base once already, a **sorted grep of every migration that defines `book_class` proves 163 is the newest before the drop**.

**The guest-pass waiver (Decision 26) uses the same screen and records the same version**, and the desk/paper path (`record_document`) records the version too.

**`require_waiver` is the switch.** Off → no editor prompt, no banner, exactly as today. **On with no waiver content yet:** the setup checklist gains a waiver item, and the member booking screen must never show an empty waiver — booking is refused with a clear sentence pointing at the studio, because a blank agreement is worse than none.

**Build in two halves, each through the full gate loop.** (A) `waiver_versions` + `waiver_signatures` tables + the Settings editor (text/PDF source) + the phone-first signing screen with the drawn signature + the signed-PDF-and-PNG-via-self-sign path + the member-self storage policy + the 2.1.4 re-sign gate + tests. (B) the guest-pass door (`enforce_guest_waiver` re-sign check) and the setup-checklist item.

---

## 33 — Calendar export: an .ics on the booking email, a per-person subscribable feed, and Add-to-calendar buttons

A web app cannot write to a phone's calendar silently. "Auto-add" is therefore three things: an **.ics attachment** on the confirmation email (Gmail/Apple Mail turn it into one-tap add), a **subscribable feed** (webcal) per person that stays in sync, and an **Add to calendar** button per class. On by default — basic convenience, no trace when unused; the one opt-in is the instructor's per-booking email.

**One .ics builder, in SQL**, because the email pipeline is entirely SQL and there is no service-role client — the email attachment, the buttons and the feed all call the same builder. A VEVENT carries `UID` = booking id (member) or occurrence id (instructor), `DTSTART`/`DTEND` as UTC instants (`…Z` — exact, and a fixed single event needs no VTIMEZONE block), `SUMMARY` = class name, `LOCATION` = studio address, `DESCRIPTION` = instructor first name + a link to the class (member) or the headcount (instructor). Text fields are iCal-escaped and lines CRLF-folded. `class_moved` re-emits the same UID at a higher `SEQUENCE` so the event updates in place; the studio-cancel email (`class_cancelled`) emits `METHOD:CANCEL` so the event leaves the calendar.

**SEQUENCE has two sources, and both move with the thing the event shows.** A member event (UID = booking id) uses `epoch(bookings.updated_at)`. An instructor event (UID = occurrence id) shows the **headcount** in its DESCRIPTION, so its `SEQUENCE` and `LAST-MODIFIED` come from `epoch(class_occurrences.updated_at)` — and a booking write DOES touch it: `book_class`/`cancel_booking` do `update class_occurrences set booked_count = …`, which fires the `class_occurrences_updated` → `set_updated_at()` trigger. So a new booking on an instructor's class raises that event's SEQUENCE in the feed, which is what makes the headcount re-sync. (Verified against the live trigger, not assumed.)

**Attachment plumbing:** `send_via_resend` gains a nullable ics param (base64, `text/calendar`) by **drop-and-recreate, 6 → 7 args** — rebuilt from migration 143's file, every caller grepped before the drop (143's own 6→5 regression was caught by a suite, not by reading), every revoke re-asserted, and the migration asserts it is reachable by neither client role. `deliver_notification` builds the ics from the notification's payload for a fixed set of calendar-bearing templates and passes it — the renderer stays as-is. `booking_confirmed` gains a **Manage this booking** link to the member class-detail screen (login required; **no tokenised one-click cancel** — that would be a pre-login write anyone holding the email could fire) and the ids the ics needs. The `booking_email` preference gates the confirmation and its attachment together.

**The feed is the eleventh pre-login surface.** One token per person (member or instructor), **hashed at rest like `member_invites`**, shown once, revocable and re-mintable from `/settings` (member) and `/instructor/me` (instructor). `calendar_feed(token)` is SECURITY DEFINER granted `anon` — the token is the credential (the stripe-webhook shape) — and returns that person's own future bookings (member) or assigned classes (instructor), **scheduled only, published months only (Decision 25), nothing about anyone else, no member data in an instructor's feed beyond headcount**. A Next route serves it as `text/calendar` at a `.ics` URL (calendar apps fetch directly; PostgREST returns JSON), using the anon key against the function — no service-role client. Cached like `public_schedule`. `public_schedule_test`'s "anon surface is exactly ten" and CLAUDE.md's canonical list both become **eleven, naming `calendar_feed`, in the same commit as the function.**

**Instructor per-booking email is opt-in, off by default** (`instructors.email_each_booking`), because Reform at 21+ classes/week × 6 beds is 100+ "one person booked" emails a week. The calendar is the per-booking channel: the feed's live event carries the headcount and updates as bookings change. Members have `notification_preferences`; instructors had none, so this is their first.

**Amendment (Deanna's decision) — the per-instructor opt-in becomes a per-tenant switch, and an instructor cannot opt out.** For Reform Collective an instructor must ALWAYS know when a booking lands on or leaves their class; that is not the individual's choice to decline. So `instructors.email_each_booking` (and the `/instructor/me` toggle) is removed and replaced by `studio_settings.instructor_booking_alerts` — a per-tenant switch, **off by default product-wide** (the `all_off` canary stays at zero on defaults alone), controlled by the studio in Settings → Instructors, with no instructor opt-out. Reform turns it on. **And the alert coalesces per class, not per booking:** a booking, a cancellation, a late cancel, a waitlist promotion or a desk booking on an assigned class queues ONE notice per class per 15-minute window (deduped on `dedupe_key = instr_booking_alert:<occurrence>:<15-min bucket>`, scheduled for the window's end so a second change inside it UPDATES the pending notice rather than adding one). The email names the class, the date/time in the studio zone, the current headcount and spaces, and what changed since the last notice ("+2 booked, 1 cancelled"), with a link to the roster in the portal. It goes ONLY to the assigned instructor (their login), never for an unassigned class, and never for a class in a draft month (Decision 25). This addresses the very volume the original opt-in was hedging against — 100 one-line emails a week become at most one per class per quarter-hour — so making it mandatory is affordable. The original "the calendar is the per-booking channel" still holds for a studio that leaves the switch off; the feed's live headcount is unchanged.

**Buttons:** member class-detail and booking-confirmation screens; instructor My-week per class and a whole-month button (the feed's content as a one-off .ics). All the same SQL builder.

**Member self-cancel sends no email, and that is decided, not deferred** — `cancel_booking` queues nothing to the cancelling member today and gains nothing here. The member acted deliberately and the app confirmed; the **subscribed feed is the sync channel** that drops the event. A stale one-tap event (added from the attachment, then self-cancelled before the feed resyncs) is the member's own booking to remove — not worth an email nobody asked for. `METHOD:CANCEL` attachments are reserved for the studio-cancel and move paths, which already email the member.

### Amendment — the emailed calendar was broken: empty attachment, no Gmail card, and no year on the date

A booking confirmation arrived in Gmail with a **0-byte `studiior.ics`** and no calendar card. Read-only diagnosis found three faults, fixed together here; the in-app download routes and the webcal feed were **never** affected (they return the `.ics` as the raw response body, no base64, no Resend), so this touches only the emailed attachment and the human date.

**1. The empty attachment was Postgres MIME-wrapping the base64.** `send_via_resend` built the attachment `content` with `encode(convert_to(p_ics,'UTF8'),'base64')`, and Postgres's base64 encoder inserts a newline every 76 characters (RFC 2045). The rendered `.ics` itself was valid and 542 bytes; its base64 carried 9 embedded newlines, and Resend delivered it as 0 bytes. Fix: emit single-line base64 — `translate(encode(…,'base64'), E'\n', '')` — which is what every Resend SDK sends. `create or replace`, no signature change, ACL preserved and re-asserted-by-assertion.

**2. No Gmail card, because the calendar was METHOD:PUBLISH with no ORGANIZER/ATTENDEE.** Gmail only renders its event/RSVP card for an **invitation** — METHOD:REQUEST with an ORGANIZER and an ATTENDEE whose address matches the recipient (Apple Mail is more lenient and shows "Add to Calendar" for a valid PUBLISH attachment, so fix 1 alone restored Apple Mail). So the **emailed** calendars become invitations: `booking_confirmed`, `class_moved`, `class_cancelled` (member) and `instructor_assigned`, `booking_for_instructor` (instructor) now carry **ORGANIZER = the studio's contact email** (fallback `notifications@{from_domain}`) and **ATTENDEE = the recipient's own email** with `RSVP=TRUE;PARTSTAT=NEEDS-ACTION`, and the VCALENDAR METHOD is **REQUEST** (add/update) or **CANCEL** (`class_cancelled`, `STATUS:CANCELLED`, same UID, higher SEQUENCE). `class_moved` keeps the same UID at a higher SEQUENCE. **The download routes and the webcal feed stay METHOD:PUBLISH with no ATTENDEE** — they are a file the person adds to their own calendar, not an invitation, and they work today. The mechanism: `ics_vevent` gains optional `p_organizer`/`p_attendee` (raw `ORGANIZER:mailto:`/`ATTENDEE;…:mailto:` lines, folded not escaped, since RFC params use `;`/`,`); `ics_member_vevent`/`ics_instructor_vevent` gain optional attendee/organizer params that default null (so the unchanged route/feed callers stay PUBLISH-shaped); `notification_ics` resolves the recipient's email (member row for member templates, staff row for instructor templates) and the studio organizer, and sets REQUEST/CANCEL; `send_via_resend` derives the `content_type; method=` from the calendar's own METHOD line for REQUEST as well as CANCEL and PUBLISH. **Trade-off, accepted:** the emailed `.ics` now contains the recipient's email as ATTENDEE and reads as an invitation from the studio (RSVP replies route to the ORGANIZER address) — which is the correct semantics for a class the studio booked them into, and the only shape Gmail will card.

**3. The date carried no year.** `{when}`/`{old_when}`/`{grace_ends}` were formatted `'FMDay FMDD FMMonth, HH24:MI'` → "Monday 9 November, 07:00". The named families get `YYYY`: the booking emails (`queue_booking_notifications`, `queue_class_moved`, `queue_occurrence_cancelled`), the cover/substitution family (`request_cover`, `approve_cover_request`, `decline_cover_request`, `accept_cover`, `sweep_cover_escalations`, `queue_substitution`, `reassign_occurrence`), the shift/assignment family (`apply_for_shift`, `approve_shift_application`, `decline_shift_application`, `open_shift`, `queue_instructor_assigned`) and the platform grace warning (`queue_platform_warning`). `class_reminder` ("tomorrow") and the weekday-only brief text are left alone; `create_occurrence`/`move_occurrence` already carried the year on their availability warning. **Out of scope, found year-less and flagged for a follow-up decision** (not the named families): `queue_waitlist_offer`, `queue_waitlist_missed`, `queue_instructor_booking_alert`, `sweep_guest_waivers`, `sweep_instructor_confirmations`, and the staff previews `archive_impact`/`availability_conflicts`.

**No new anon surface — stays exactly eleven.** The feed, buttons and their PUBLISH output are unchanged.

---

## 31 — The settle date gains a second shape, and Reform's payroll contract is expressible

**Not yet built — this entry is the decision, approved before the migration.** Migration 140 (Decision 22's follow-on) gave the settle date one shape: a **weekday** rule, `pay_settle_dow`, resolving to the first such weekday strictly after the period's `ends_on` ("the Friday after close"). Reform Collective's instructor agreement pays **on the 15th and the last day of the month** — a semimonthly cycle whose pay date IS each period's own end — and no weekday rule can say that. So the settle rule gains a second shape and the weekday example in earlier notes is superseded for this tenant.

### A fixed offset in days after the period closes, beside the weekday rule

`studio_settings.pay_settle_offset_days` (nullable int) is the number of days after `ends_on` that pay lands — **0 means the close date itself**. It sits beside `pay_settle_dow`, and **exactly one may be set**: a CHECK enforces `pay_settle_dow is null OR pay_settle_offset_days is null`, and the offset is **bounded** — `pay_settle_offset_days is null OR (pay_settle_offset_days between 0 and 31)`, so a fat-fingered 300 cannot push the pay date a year out. **Both null means no date is shown**, exactly as today (the feature stays off by default, per tenant). `pay_settle_on()` gains the offset branch and stays **pure and immutable** — it takes `ends_on` plus whichever shape is set and returns a date, reading no tenant state and guarding nothing, so it can be computed anywhere a statement is rendered. Both shapes are pinned to `ends_on`, never to when a manager actually closed the period, so the promised date is stable whether the period is closed on time or late.

### "The 30th" is rendered as "the last day of the month", because that is what the period end is

The contract says "the last day of the month"; a semimonthly studio with `pay_period_second_day = 16` runs a second period of `16..month-end`, so its `ends_on` already **is** the last day — the 28th, 29th, 30th or 31st, whichever the month has. With `pay_settle_offset_days = 0` the pay date is that same last day, and February resolves to the 28th or 29th with no special case, because the date comes from the period boundary, not from a stored "30". The first period (`1..15`) ends on the 15th and pays the 15th. This is exactly "the 15th and the last day", expressed as `semimonthly + second_day 16 + settle offset 0`, not as a new rule.

### The trade-off of offset 0, and why the screen recommends a small offset

Paying **on** the close date is the tightest promise, and Decision 28 is the reason it can bite: a class that ran is written **held** until the instructor checks themselves in, and `close_pay_period()` refuses while any record is held (PT409). Only records confirmed by then are payable, so a period cannot be closed — and therefore cannot be paid — while a check-in is outstanding. With `offset 0`, an unconfirmed class on the 15th means the pay date and the close both slip until it is confirmed or a manager releases it. So the settings screen **recommends a small offset** (a day or two), which leaves room to chase or release held records before the promised pay date arrives, while `offset 0` stays available for a studio whose check-ins are always in on time. This does not contradict Decision 28; it is Decision 28's held-record rule seen from the pay-date end.

### The conversion bonus, recorded as configured (not changed)

Decision 22 already settled the mechanism: the bonus is attributed to the instructor of the member's **first ever class** (`conversion_attribution = 'first_class'`, migration 083 — attribution is **read-only** in the UI, because last-class attribution rewards whoever taught the day a card cleared, close to random), **one per member ever** (unique index), fired from the membership insert so cash and Stripe behave identically, and **clawed back as an adjustment** in the next open period on refund. What Decision 31 makes reachable is the **configuration**: `conversion_bonus_enabled` (off by default — no bonus, no trace, the `all_off` canary must stay at zero), `conversion_bonus_cents`, `conversion_window_days` (the member must buy within this many days of that first class; Reform's is 30), and **`membership_plans.counts_for_conversion`** per plan (which purchases qualify — Reform's paid plans yes, the drop-in no). None of these had a screen, so Reform's contract could not be entered at all.

### `pay_period_anchor` is weekly/fortnightly only

The period **mode** (`pay_period_mode`) already exists with four values. `monthly` uses the calendar month and `semimonthly` uses `pay_period_second_day`; neither needs an anchor. `weekly` and `fortnightly` need a reference date to know which day the cycle turns on — that is `pay_period_anchor`, and the settings screen shows it **only for those two modes**, absent for the mode Reform runs.

### Contradiction check — none

Read against Decisions 22, 28 and 140: Decision 31 **extends** 140 (a second settle shape beside the weekday one, same `ends_on` pin, same off-by-default posture) rather than replacing it; it **relies on** 28 (the held-record rule is what makes the offset-0 trade-off real) rather than working around it; and it **exposes** Decision 22's conversion mechanism as configuration without altering the attribution, the once-ever rule, or the clawback. The only thing superseded is the illustrative "fortnightly on Friday" in earlier notes, which was an example, not a commitment.

### Open — per head at the cutoff, or per attending head

Per-head pay is computed from **`booked_at_cutoff`** — the headcount snapshotted at the core cutoff — **not** from who actually attends. Verified from `compute_class_pay_run` (migration `20260831430000`): `v_heads := coalesce(o.booked_at_cutoff, 0)`, and the group ran/committed branch is `base + greatest(0, v_heads − per_head_threshold) × per_head + (v_heads ≥ capacity ? full_house_bonus : 0)` — so the **full-house bonus uses the same cutoff count**. A member who books *after* the cutoff and turns up is a real body in the room who earns the instructor **no** per-head and cannot tip the class into the full-house bonus; conversely a booked no-show still pays. This is Decision 22's "committed is terminal, never from attendance", and it cuts both ways. **Whether Reform's contract means "₱75 per head at the cutoff" or "₱75 per attending head" is UNRESOLVED, and the two diverge exactly for a late booker — it must be answered before the first period is paid.** The build only records which count is used; it does not change the behaviour.

**Where:** a new migration adding `pay_settle_offset_days` + the CHECK and the `pay_settle_on()` offset branch; UI for the settle rule, `pay_period_anchor` (weekly/fortnightly), the conversion block, and the per-plan `counts_for_conversion`. **Reuses:** migration 140 (`pay_settle_on`), 134 (period modes), 083 (conversion attribution), Decision 28 (held records). **Status:** approved as a decision; build pending. **Off by default** — asserted inert by the `all_off` canary.

---

## 30 — A new member's first class is free

**Built: migration `20260831630000` (free first class).** Optional per studio, **off by default** (`studio_settings.free_first_class_enabled`), toggleable at any time and leaving no trace when off. A stranger signs up on the studio's own subdomain, books a class, and it costs nothing — no host, no invite, no card, no credits. Reform Collective opens with no card provider (Stripe does not serve the Philippines), so this is how a first-timer gets in the door at all. A per-studio `free_first_peak_allowed` (default true) lets a studio keep free seats out of its peak hours.

**It shares Decision 26's once-ever ledger rather than adding a parallel one.** `guest_passes` is already "who has had their one free class here". A self-signup free class is recorded as a `guest_passes` row with **no host** (`host_member_id` becomes nullable) — so the free-once key spans both doors automatically, and a person is refused `already_had_free` whether they came as a guest first or a signup first. One free class per person, whichever route. The waiver-at-check-in gate, the host-cancel/attend sync and the conversion derivation are all Decision 26's, reused unchanged.

**Turning it off never charges anyone retroactively.** The seat is `payment_source = 'comp'` — nothing consumed, nothing charged, ever — so an existing free booking stands on its own after the switch flips.

### The once-ever key is a normalized email, and normalization is for the KEY ALONE

The free-once rule is keyed on email, and two addresses that reach the same inbox must count as one person. `normalize_email_key(email)` is a single **immutable** function, **shared by Decision 26 and Decision 30**. It does: lowercase, trim, **strip the `+tag`** from the local part for every provider, and **strip dots** from the local part for `gmail.com` / `googlemail.com` (folding `googlemail.com` to `gmail.com`, the same inbox). So `A.B+promo@gmail.com`, `ab@gmail.com` and `a.b@googlemail.com` are one person; `a.b@example.com` and `ab@example.com` are two.

**The key answers exactly one question — "has this person had their free class, or are they already a member here" — and it answers it in exactly these places:** the free-once unique index on `guest_passes`, and the two eligibility refusals `already_had_free` and `already_member`, in both `guest_pass_eligibility` (the guest door) and `free_first_eligibility` (the signup door). Both refusals must use it: `already_member` on raw `lower(email)` let an existing member `a@gmail.com` take a free class as `a+1@gmail.com`, because the variant matched no member row and no pass yet existed to trip the index.

**It is used for NOTHING that links or addresses a person** — not sending, not display, not login, not account claiming or member linking. The raw address the person typed lives on their `members` row and is what mail is addressed to and what claiming and login match on. `guest_passes.guest_email` is a ledger column, **stored lowercased and trimmed at both doors (`book_guest` and `book_first_free`), never plus- or dot-mangled**, and read ONLY through `normalize_email_key` — the once-ever key is **computed, never stored**, and the unique index is a *functional* index over that column. Dot- and plus-stripping decide who has already had their free class; they must never decide who receives an email or which account someone signs into.

**Where:** migration `20260831630000`; extends Decision 26's `guest_passes` ledger. **Status:** settled. **Reuses:** Decision 26 (once-ever ledger, waiver-at-check-in, conversion). **Off by default**, asserted inert by the `all_off` canary.

### AMENDMENT (free first classes are grouped) — Deanna, 2 Oct 2026

A free first class (Decision 30) must never be the only person in a room, because the instructor agreement pays the 1-pax rate for it and the studio earns nothing. Four per-studio controls, all defaulting to today's behaviour so the all_off canary is unchanged: (1) `free_first_core_only` — free seats only on core classes; (2) `class_series.free_first_allowed` — which recurring classes accept free seats (default true on every series; a studio curates by turning others off); (3) `free_first_seats_per_class` — cap on free seats in one class (null = no cap); (4) `free_first_confirm_at` — a free seat is PROVISIONAL until the class holds at least N people in total (paid or free), at which moment every provisional free seat in it is confirmed immediately and the person is told; null = confirmed on booking (today). A provisional seat still unconfirmed at the class's own cutoff (core: `core_cutoff_hours` before; flex: the flex deadline) is released: the person is told their booking wasn't confirmed, shown the next trial-friendly classes that already have people, and keeps their free class. Confirmation is a latch. Paid bookings are never provisional. The free booker's list shows only eligible classes, fullest first. The confirmed email states the no-show rule: cancel ahead or rebook, or the free class is used. Instructor pay is untouched. Free bookings made before this amendment are grandfathered: confirmed as they stand, never released. Reform: core only, curated trial-friendly classes, cap 6, confirm at 3.

**Built: migrations 206 (`20260832110000`, the enum value alone) + 207 (`20260832120000`).** `studio_settings` gains `free_first_core_only` (default false), `free_first_seats_per_class` (null, CHECK > 0), `free_first_confirm_at` (null, CHECK >= 2); `class_series.free_first_allowed` (default true); `bookings.provisional` (default false, true only for a comp seat awaiting confirmation) and `bookings.confirmed_at`; the `booking_release_reason` enum gains `trial_not_confirmed` (its own migration step — the enum trap). **Eligibility** (`free_first_eligibility` + the list) adds: Decision 48 visibility passes AND (not `core_only` or tier = core) AND `series.free_first_allowed` AND (cap null or free seats in it < cap); the list orders eligible classes by headcount desc (counting provisional seats) then start, and returns `flex_not_allowed` / `not_trial_class` / `free_seats_full` as sentences. **Provisional** (`book_first_free`): a comp seat is `provisional = (confirm_at is not null and headcount after insert < confirm_at)`; `booked_count` still counts it, and `evaluate_commitment`'s counting is NOT changed. **Immediate confirmation** (`confirm_provisional_seats_run(occurrence)`): called after every booking insert on that occurrence — when headcount >= `confirm_at`, every provisional seat is confirmed (latch, never reverts) and each member told (`free_booking_confirmed`, dedupe `free_confirmed:<booking>`). **Release at the cutoff** (`evaluate_commitment`, both paths, BEFORE counting): a still-provisional seat → `cancelled` / `trial_not_confirmed`, `booked_count` decremented, the `guest_passes` once-ever row removed (the person keeps their free class), `free_booking_not_confirmed` queued with the next three eligible trial-friendly classes that have someone in; then the existing evaluation runs on what remains. A manual `cancel_occurrence` (any cause) releases the same way. **Grandfathered:** existing comp bookings stay `provisional = false`, never released. Member-facing texts are verbatim in the build brief; instructor pay untouched. **Reform:** core only, curated series, cap 6, confirm at 3 — the owner sets these in the UI. **Status:** settled, on hosted (drift IN STEP, anon twelve, guard probe PT403). **Reuses:** Decision 21 amendment (the pending/confirmation member state and sweep), Decision 26 (once-ever ledger), Decision 48 (member visibility). **Off by default** (every new control defaults to today's behaviour), asserted inert by the `all_off` canary.

---

## 29 — Instructor claiming: inverting how a month gets staffed, per tenant

**Built: migrations 149–156 (`20260831540000`–`20260831610000`), on hosted.** The assigned model staffs a month top-down: staff assign a roster, publish it (Decision 25), instructors **confirm** what they were given, and carry-forward fills gaps on silence. Claiming **inverts** it, **per tenant, off by default** (`studio_settings.claiming_enabled`): the studio publishes a month of **unassigned** classes — each already marked core or flex by its series — and instructors **claim** the ones they want, with staff **approving every claim**. The tier is fixed by the series; the claim button does not ask which tier, it tells the instructor which it is and where they stand this week.

### It is Decision 17's apply-and-approve, and it does not break 17/18

The spine is Decision 17 unchanged: `apply_for_shift` flips a class `open → pending_approval` and notifies staff; `approve_shift_application` assigns via `move_occurrence` (which hard-gates the validity window and the double-booking exclusion), auto-declines every other pending application, and notifies each. **Instructors apply, staff approve every claim, and there is no self-release** — a claim is an application, approval is the studio's act, and nothing lets an instructor assign or unassign themselves. So Decision 17 (instructors apply for open shifts) and Decision 18 (cover is always granted by staff, no self-release however urgent) both still hold; claiming is those mechanics pointed at a whole published month rather than at one opened shift. What is new is only the eligibility a *claim* is held to (a cover apply is looser): published month, the instructor's stated availability for it, and the core cap below.

### Superseded, not run alongside

When claiming is on, roster confirmation (Decision 25) and carry-forward are **superseded, not additionally run**: a claim IS the confirmation, and carry-forward has no assigned baseline to carry. `publish_month` already emails nobody for unassigned classes (its inner join to `instructors`), and a claiming studio keeps `carry_forward_enabled` off, so those flows go inert without being re-issued. A studio uses **either** the assigned roster **or** claiming, never both.

### The soft core cap, and how it squares with "commitments never affect scheduling"

A per-instructor **soft ceiling** on how many **core** classes they may self-claim in a studio week (`instructors.core_weekly_cap`, null → `studio_settings.core_claim_default_cap`, default 3). Flex and `always` claims are uncapped. It is **soft**: past the cap `apply_for_shift` refuses the self-claim with the numbers and offers "ask anyway", which sets `shift_applications.over_cap` and proceeds; staff see the flag on the approval screen and approve or not. **The cap guides, never blocks.**

This does **not** contradict Decision 65's rule that *the commitment never affects scheduling*, and the reconciliation is structural rather than verbal. The commitment (`instructor_commitments.min/target_per_week`) is a **floor and a reporting measure**, and Decision 65 forbids it from touching **assignment-engine eligibility** — that is unchanged here: the engine still ignores it, and it is not read by claiming either. The cap is a **different number with the opposite job** (a ceiling on self-claiming), on its **own column**, and it is deliberately kept off the assignment engine: staff assigning through the engine are never held to it, and even in the claiming flow it is overridable. So the commitment rule holds literally, and the two never share a lever.

**The residual, recorded honestly:** the cap *is* a scheduling-adjacent lever — it softly shapes which core classes an instructor self-claims, which the commitment is explicitly not allowed to do. The distinction that keeps it clean is that the cap is (a) not the commitment, (b) soft and staff-overridable, and (c) never an input to the assignment engine — so it guides self-service without ever *deciding* the roster. If a future change makes the cap hard, or feeds it to the engine, this reconciliation breaks and Decision 65 would have to be revisited.

**Where:** migrations 149–156; `claiming_enabled`, `core_claim_default_cap`, `instructors.core_weekly_cap`, `shift_applications.over_cap`; `instructor_core_cap`, `instructor_claimable`, `claim_ranking`, claiming-aware `apply_for_shift`. **Status:** settled and on hosted. **Extends:** Decision 17 (apply/approve), Decision 25 (publication). **Coexists with:** Decision 22/65 (the commitment as a measure). **Off by default**, inert on the `all_off` canary.

---

## 28 — The instructor checks themselves in for pay, and a held record blocks the period from closing

**Built: migrations 134–137.** Decision 22 computed what a studio owes each instructor and wrote a pay record at the class's terminal transition — but nothing recorded that the instructor was actually in the room. This closes that gap without turning it into surveillance: **the instructor checks themselves in**, in the portal on their My week screen, one tap on the class, and only within a window.

**The window is the member check-in window, reused not reinvented.** Migration 007's `checkin_opens_minutes_before` / `checkin_closes_minutes_after` already define "around the class"; a class-for-pay confirmation uses the same two settings rather than a hardcoded 60/30 or a new pair of columns. Outside it, `instructor_confirm_class()` refuses (PT422).

**A ran class's pay is written HELD, and a held record cannot sit in a closed period.** `record_class_pay` stamps `confirmed_at` null on a class that ran until the instructor confirms (method `self`); a class that did NOT run is auto-confirmed (method `auto`) and needs no check-in, because Decision 22 already says what a not-running class pays and there is no room to be in. **`close_pay_period()` refuses while any class record is held, and names the count (PT409)** — closing is the studio asserting "this is what we owe", and an unconfirmed class is precisely the thing still in question. Staff release a held record on the instructor's behalf with a reason via `confirm_class_for_pay()` (manager, method `manager`, audited `pay_record.released`), so a forgotten tap never traps a period.

**Payment frequency is a setting, not a constant.** Decision 22's periods were fortnightly and days-based with no control to set them. A studio may now choose weekly, fortnightly, monthly, or twice-monthly on set days (`pay_period_mode` + `pay_period_second_day`); `ensure_pay_period()` branches on the mode in studio-local dates. Default fortnightly leaves every existing period exactly as it was.

**Proof of payment is recorded, never moved.** Studiior does not move money (Decision 22 stands). On a CLOSED period a manager records that the studio paid an instructor elsewhere — the date, the method, a reference, an optional receipt — into `instructor_pay_settlements`, so the instructor's statement reads paid and "did you pay me" stops. An OPEN period cannot be marked paid (PT409): you pay what the closed statement says. The receipt lives in a private per-studio bucket keyed so an instructor reaches only their own; managers read all, an instructor reads their own. This is the member side's `record_manual_payment` posture — Studiior records what the studio says happened and does not verify it.

**The CSV export must equal the statement.** `pay_period_export()` returns the statement's exact line shape across every instructor plus a per-instructor summary; the app only formats it. If the CSV and the statement disagreed, the CSV is what an accountant believes and the studio has a problem — so they read the same source and the suite asserts parity three ways (row count, total, each line's amount).

**An instructor no-show is THIS check-in, not a cancellation cause — and there must never be a fourth cause for it.** A `cancellation_cause` says the studio decided something about the *class*; an unconfirmed (held) pay record is a fact about whether the *instructor* turned up. They are the same real event modelled from two sides, and the check-in wins. Adding `instructor_no_show` to `cancellation_cause` (migration 079's enum: `unmet_minimum`, `studio_fault`, `force_majeure`, `closure`) would let a class read `instructor_no_show` while its pay record sits `confirmed` — the two disagreeing about the same class, with no rule saying which is true. So a no-show is represented as a held record that is never released: `close_pay_period()` refuses while it is held, and a manager either releases it (the instructor did teach — a forgotten tap) or leaves it unreleased and unpaid (they did not). The zero-pay outcome the contract wants is "held and never released", not a cancellation. **Do not add the cause.** (Cross-checked against Reform Collective's instructor agreement, September 2026.)

---

## 27 — Studio announcements, one-way, and never a feed

**Built: migrations 131 and 132.** A studio posts something and members see it on their Home — a workshop, a closure, a new instructor, a price change, an event. Title, body, an optional photo (the migration-116 focal-point treatment, since `object-fit: cover` on a phone crops a wide image to a sixth of itself), a start and end, a draft/published state, an audience (members, instructors, or both), and a pinned flag. Staff create, edit, publish and unpublish; members see published ones in range, newest first with pinned on top, and dismiss the ones they have read; a pinned one stays until it ends.

**ONE-WAY, and it must not become a feed.** Decision 13 excluded a community feed — posts, comments, likes, friend connections — from V1, and that stands. This is studio-to-members only: no replies, no reactions, no member-authored anything, no threading. It is recorded here so that nobody grows it into the very thing V1 excluded. The audience field is the only social axis, and it points one way.

**Optional per studio BY EXISTENCE — no switch.** A studio with no published, in-range announcement shows no "What's on" section on Home, absent not empty (the challenge pattern). Unlike challenges or guest passes, there is no enable toggle: announcements are a basic communication tool every studio plausibly uses (a closure, at least), so the staff admin is always in the manager's rail, and member visibility is pure existence. Turning it off is deleting or unpublishing, not a setting.

**The audience field earns its place.** "Closed for Christmas" is for both members and instructors; "new intro offer" is members only. Instructor-audience announcements surface in the portal (096/097), never on a member's Home; a members-only one never reaches an instructor.

**Notifying is opt-in, off by default.** A studio that emails every announcement trains members to ignore them; a closure is the case where they genuinely should be told. So publishing offers a "notify" checkbox, and only then are members of the audience emailed — once, keyed on the announcement, never re-sent on a re-publish. Instructors are not emailed (they see it in the portal); that is a noted gap, not a decision to keep it that way forever.

**AMENDMENT (migration 168): announcements are two TYPES, gain a link, and move down Home; the built-in free-first banner is retired in their favour.** Migration 166 added a dismissible one-line strip at the top of `/book` for *pinned* posts — but "pinned" was carrying two jobs at once (first-in-What's-on AND the strip), and a full What's-on post is the wrong shape for a one-line strip. This splits the concept cleanly.

- **`announcements.kind` is `'post'` (default) or `'banner'`.** A **post** is what exists today — title, body, optional photo, dates, audience, pinned — rendered in the "What's on" section, pinned first. A **banner** is title only (≤ ~120 chars, enforced), no photo, no body, rendered as the dismissible one-line strip at the top of Home AND Book. **The strip now shows `kind='banner'` only; pinned no longer drives it.** Every existing row becomes `'post'` by the default, so nothing already published changes.

- **An optional link on ANY announcement** — `link_url` (https only, validated in the writer and by a CHECK) and `link_label` (default "Learn more"). On a What's-on post it is a button under the body. On a banner, a link makes tapping the strip open the link (with a small arrow to signal it) instead of expanding; a banner with no link behaves as before. A same-host link (into the member app) opens in place; an external one opens in a new tab.

- **Home order changes.** Banner strips sit at the very top, above everything. Then the existing Home content (next class / hero, waiver banner, coming up), then Challenges, then **What's on LAST, below Challenges** — it is for events and longer reads, not the first thing on the screen. Book shows banners only (no What's on).

- **The banner strip is the one FILLED bar on the screen** — `accentRamp().solid` with its measured `onSolid` text (the primary-button pair), so it separates from the tinted cards on every preset and accent. No raw hex: a fixed green would be wrong on a green-accent studio and on Bold. The X and the arrow take `onSolid` too. Measured at 375 on all four presets.

- **Dismissal is the existing `dismiss_announcement`**, so one X clears a banner on Home and Book together. Multiple live banners stack; the studio should keep it to one or two, but nothing is enforced.

- **The built-in free-first banner on `/book` is REMOVED.** The studio's own banner announcement is the message now; free-first eligibility is still carried by the "Book — first class free" row buttons and the class-detail block, which stay. The `free_first_banner` dismissal key and its action are dropped; `member_dismissals` (166) stays for future per-member keys.

- Instructor audience is unchanged: a banner with audience instructors/both shows as a strip in the portal too.

---

## 26 — A member may bring a guest, and the guest's first class is free

**Built: migration 127.** Optional per studio, off by default (`guest_passes_enabled`), and a studio that never turns it on sees no "bring a guest" option in the member app and no guest column anywhere — Decision 24/25's optional-not-merely-configurable rule again.

**The mechanic is acquisition, not a discount.** A member invites a friend to the class they are booking; the friend's first class costs nothing; and a real member record exists by the time the friend wants to book again, so buying a pack is a purchase rather than a signup.

**Free once, ever, keyed on email.** One free guest class per person at a studio, enforced by a unique index on `guest_passes(studio_id, lower(email))` and a check against `members` — a returning or lapsed member is not "new". The two are distinct refusals ("already had a free class" vs "already a member here").

**The guest books the HOST's class, at the same time — a referral, not a free pass.** `book_guest()` ensures the host holds a real seat (booking them if they had none) and gives the guest a second seat in the same occurrence, so a guest never takes a seat the host didn't also take and a full class needs TWO free seats — refused as "only one seat left" when one short.

**One guest at a time.** A partial unique index on `guest_passes(studio_id, host_member_id) where status in ('invited','confirmed')` blocks a second invitation until the current guest has attended (or cancelled). This stops ten invitations on a Monday and ten unfillable free seats.

**The guest seat is free and separate.** `payment_source 'comp'`, no membership, no credit consumed, no peak allowance — two seats, one paid for.

**If the host cancels, the guest's booking STANDS** and the guest is told their friend cancelled (a trigger; the guest keeps their seat). The host's own cancellation follows the normal rules — late is late.

**The waiver is signed in the app before the class, and an unsigned waiver blocks CHECK-IN, not booking.** A guest account created by somebody else has signed nothing, and `members.waiver_signed_at` gates booking (§2.1) — so the guest is booked anyway and a trigger on `check_ins` refuses check-in until they sign (`sign_waiver()`, self-serve). A guest who has not signed by the time the class starts is turned away and the desk is told.

**The account is a real member, status 'lead'** (Decision 15 already lets a lead book a drop-in). The guest is invited to claim (the migration-073 invite path) and is an ordinary member afterwards — nothing special except that their one free class is spent. **Conversion is derived**, never stored: a guest converted iff their member row holds any membership, which is the number `guest_pass_report()` and the `dashboard_guest_kpi` surface — the figure that says whether this works at all.

**Chasing the waiver, and the paper fallback (migration 128).** An unsigned guest turned away at the door with nobody having chased them is the worst first impression of a business they were weighing. So `sweep_guest_waivers()` (every 15 minutes, a 4-hour lead) reminds the guest if their pass is still unsigned a few hours before the class AND nudges the host — the friend who invited them is who can actually make it happen — each once. And front desk records a waiver signed ON PAPER at the door through `record_document`, which confirms the pass and clears the check-in gate exactly as signing in the app: a studio hands an unsigned guest a form, it does not send them home, and the product has to be able to record that.

****Instructor guests are not built.** Guests are member-brought only; if a studio-brought guest ever arrives it is a different mechanism.

**Pricing note, recorded not enforced:** Reform Collective's Intro Offer (three classes for 1,999 PHP) is undercut by a free guest class — a pricing question for the studio, so the copy does not advertise both in the same breath.

---

## 25 — A month is a draft until the studio publishes it, and instructors confirm their roster when it is

**Built: migrations 112 and 113.** Optional per studio, off by default, and a studio that never turns it on sees no draft state, no publish button, no month gate and no roster email — Decision 24's optional-not-merely-configurable rule again. Reform Collective is the studio that wants this.

### The cycle, end to end

1. Instructors submit next month's availability by the due day (Decision 18)
2. Staff run "fill a month" — the engine assigns (migration 061)
3. Staff review and adjust, then **publish the month**
4. On publish, each instructor gets **their own roster** and confirms the month
5. Each week during the month they confirm the week (migration 067)

Both confirmations stay. The month is the agreement; the week is the check-in. Confirming the month confirms no week.

### Per studio per month, not a state on the occurrence

`schedule_publications` has one row per studio per published month. A month is the unit a studio thinks in, and a row per month makes the edges fall out rather than need code: a class added to a published month is published because its month is, publishing twice finds the row and sends nothing, and **unpublishing is not offered because there is no writer for it** — no UPDATE or DELETE policy, no function, and the table's other verbs are revoked from every client role.

**"Published" is one predicate, `month_published()`, read by everything**: the member and staff RLS policies on `class_occurrences`, `book_class()`, every instructor reader, the flex sweep and the notification seam. **History is published by definition** — any month before the studio's current one answers true, or the switch would rewrite an instructor's past weeks.

### Members: invisible and unbookable, and told why

The boundary is `occ_member_read`, not a screen. `book_class()` gains rule **2.1.1b, placed with the occurrence checks and BEFORE the booking window**: an unpublished class is invisible to a member, so a member reaching it by id is refused for the reason it is invisible — `month_not_published`, about the class — and `outside_booking_window` goes on meaning what it has since migration 002: a class on the timetable that this member may not book yet, about the member. When both apply, publication refuses first. The desk may override it with a reason, like the window, and the booking records the bypass.

The member app says the consequence on the screen: *"The timetable is published through 30 September. October opens for booking when the studio publishes it."*, and an empty day in a draft month says *"October's timetable is not published yet"* rather than "No classes on this day" — the closure rule in a new place.

### Turning it on publishes what it may not hide

Two kinds of month must not vanish the instant the switch goes on: the **current month**, which has already started, and any future month **members have already booked into** — "a month members have booked into cannot be withdrawn" is an edge of this decision, and a switch that withdrew three on its way on would break it by the back door. `set_publication_enabled()` publishes both automatically, marked `auto`, with no roster email, and the settings screen names them.

### Publishing

Manager-up and deliberate. The preview and the publish read the same facts (`month_publication_facts()`): classes, how many still unstaffed, which instructors and how many classes each, and who **cannot be emailed** because they have no login. Publishing with holes is allowed and warned, never blocked — an open shift is a real state and Decision 17 handles it. The roster email lists the classes **in the body**, dates and times, not a link to a calendar. One per instructor per month, ever; a class added later is told on its own. The result names anybody it could not reach — "published" must not read as "told".

### Before publication, instructors see nothing

`occ_staff_read` now lets desk-and-up read everything and an instructor read only published months; every SECURITY DEFINER instructor reader carries the same clause (056's rule). `queue_instructor_assigned()` — the seam the engine and cover approval both go through — refuses a draft month, so the engine fills a draft and tells nobody, and the roster email is the first they hear. The week-confirmation ask, `confirm_week()`, `unconfirmed_summary()` and `commitment_pending()` all skip draft months: a flex class nobody was allowed to book must not be cancelled for want of bookings.

### Confirming the month

`confirm_month_roster()` is one action for the whole month; flagging a class is `request_cover()` from migration 054 and nothing new. A pending cover request is the flag, not an obstacle. The studio may confirm on an instructor's behalf, as it may for a week. **A suspension-shaped rule was deliberately not built**: nothing stops the month if nobody confirms — an unconfirmed roster a week before the month is a Morning Brief item (`month_roster_unconfirmed`) and an action-centre row, and that is the escalation.

### The state nobody inside the studio can see

A studio with the switch on and the coming month — or the current one — unpublished has a full calendar in the staff app and an empty one in the member app. `month_unpublished` is the brief's loudest line, ranked above an unstaffed class because it is every class at once, and an urgent action-centre row. Both are absent for a studio with the switch off.

### Found on the way

`move_occurrence()` had checked an instructor's availability dates **after** the UPDATE and returned rather than raised, so a refusal for `outside_availability_dates` was words only: the class was already reassigned. Proved on the seed before 112 moved the check ahead of the write, and asserted in the publication suite.

### Not built, and said

Push does not exist; the roster arrives by email. A series created into a published month materialises its classes as published and tells nobody per class — the instructor's month screen counts them as "added since your roster", and that is the whole of it. A roster re-sent for a changed month is not offered: a class added later is told on its own, a class moved is told on its own, and the month screen is derived from the classes rather than from the email.

## 24 — Scarcity a studio can actually enforce: seat caps first

Decision 24 covers four things — peak allowance, daily booking caps, a suspension ladder, and seat caps on a plan. **All four are optional per studio, all off by default, and a studio with them off sees no trace of any of them.** They are three independent switches, not one feature: turning any on must not reveal the others.

This entry records the whole decision and marks which part is built. **Seat caps are built (migration 102). Peak allowance, daily caps and the suspension ladder are not.**

### Why any of it exists

A no-show fee is uncollectable without a card on file, and most design-partner studios take cash. The penalty that actually bites is the loss of a scarce thing: the class you did not turn up to, or the place on the plan somebody else wanted. Reform Collective's Unlimited Monthly is 12,000 PHP and was HIDDEN because its rules could not be enforced.

### The cancellation deadline is not duplicated

`studio_settings.cancellation_cutoff_minutes` already decides what counts as late. Nothing in Decision 24 adds a second window.

### Seat caps — settled and built

Three columns on `membership_plans`: `max_active_members` (null = no limit), `show_remaining_below` (null = never say), `on_limit_reached`. One switch on `studio_settings`: `seat_caps_enabled`, default false.

**Places are counted ACTIVE, never lifetime.** `plan_seats_taken()` is the one definition and counts `trialing`, `active`, `past_due` and `frozen`. `past_due` counts because a member who owes money has not left, and §7.3's grace exists for exactly that. **`frozen` counts because keeping the seat and the rate is what freezing IS** — a member who pauses for January and returns to find her place sold and the price raised has been given a cancellation with extra steps. Cancelling frees the place, and §7.1's price snapshot means the old rate leaves with her.

**A place is claimed inside `activate_purchase()`, under a row lock on the plan.** That is the only function in the product that creates a membership, so a cash sale and a Stripe sale are capped by one rule. The plan row is locked before the count, whether or not it is capped — deciding whether to lock by reading the cap first is the read-then-write the lock exists to prevent.

**A completed Stripe checkout is never refused.** The charge is already captured; raising inside the webhook would return a non-2xx, be retried for days, and leave somebody who has paid with no membership. `activate_purchase()` takes `p_enforce_seat_cap`, and the checkout handler passes false. The studio goes one over and every screen says "4 of 3 — over" rather than pretending. The desk is still refused while over, which is the point of being told.

**A renewal is not a second place.** Decision 23 makes a payment against an existing active membership advance its period rather than sell another, so it never reaches the cap at all.

**`on_limit_reached` is `hide` or `staff_only`, and NOT `waitlist`.** A waiting list for a place on a plan is a table, an offer with an expiry, a notification template, a staff screen and a promotion path — the class waitlist again against a different scarce thing. It is more than this pass, so the value is absent from the CHECK rather than accepted and ignored.

**Turning the switch off suspends the caps and keeps the numbers.** A studio that switches off, sells past a limit, and switches back on is over, and is told so in those words.

### Peak allowance, daily caps and suspension — decided, not built

- **Peak windows** are per studio, default off, multiple per day, studio-local and DST-aware. A class is peak if its **scheduled start** falls inside a window: 16:55 against a 17:00 window is off-peak.
- **Only plans with no credits get an allowance.** Unlimited Monthly gets 2 per week and a daily cap of 1. The packs, the drop-in and the 8-a-month plan leave `peak_allowance` null — unlimited — and are never checked against it. **Their penalty for a no-show is the credit, which `no_show_consumes_credit` already handles and which is worth real money. A plan with credits does not need a second penalty.**
- The allowance period is a **fixed week from `week_starts_on`**, never a rolling 168 hours.
- **Allowance restoration is LEDGER-SHAPED**, like `credit_ledger`: a reversing row keyed on the booking, never a decrement, because the sweep can re-run and must not refund twice. Class credits and peak allowance are independent.
- **The seam is `tg_stamp_booking_release()`**, the trigger from migration 079 that stamps `release_reason`, and its body has carried a comment marking the spot since it was written. There is **no `release_booking_entitlements()`** — that function has never existed. A booking is released from four places, which is why the seam is a trigger and not a function.
- `booking_release_reason` currently has three values and needs more (flex-not-running, staff-excused). **A new enum value cannot be used in the transaction that adds it**, so that is a migration of its own, as 036 and 077 were.
- **Infractions are late cancels AND no-shows** — both are the member failing to release a seat in time; they differ only in whether they told you. Rolling 30 days.
- **Marking a member present after a no-show restores the allowance, VOIDS the infraction, and recalculates any suspension it triggered.** The edge most likely to be got wrong.
- **An excused infraction is voided, not deleted** — a status with a reason and an actor — because the excuse RATE is the signal that a cap is set too tight, and deleting the rows makes that metric impossible.
- **Billing continues during a suspension**, and member-facing copy has to say so or it reads as a refund entitlement.
- **Suspension restricts ADVANCE booking only.** Same-day space-available still works, and the allowance still applies — a suspension does not hand out free peak slots.
- **A plan change mid-period** gives `max(0, new total − already consumed this period)`: never more than the new plan's total, never negative.
- **A configuration change never reclassifies history.**

### The waitlist half of §7 is copy, not code

A freed seat already creates a `waitlist_offer` with an expiry that a member accepts (§4.2); Decision 7 already releases the seat on a late cancel. Nothing books a member without asking, because that would consume their allowance and a credit without consent. What was missing is honesty in the copy: **a late cancellation gives the seat back to the studio, not to the member.**

### Reporting reads both ways

Very high allowance exhaustion means the cap is too tight and is suppressing revenue; near zero means it is not binding. Both readings get stated plainly rather than one being implied.

**Where:** Business Rules §2.1, §3.1 and §4.2; Data Model §7; migration 102 (seat caps). **Status:** seat caps settled and built; peak allowance, daily caps and suspension settled and not yet built. **Extends:** Decisions 12, 16 and 23. **Reuses:** `credit_ledger`'s shape, `tg_stamp_booking_release()`'s seam, §4.2's existing waitlist offer.

---

## 23 — A cash studio renews by being paid, and can see who owes it

Extends Decision 16. A studio may take cash for ever; until now nothing in the product could tell it who had not paid this month, and a recurring membership sold as cash had no billing period at all.

### The period is written at activation, from the plan's own interval

`activate_purchase()` wrote status, price, credits and `auto_renew` and left `current_period_start`, `current_period_end` and `renews_on` null. A recurring membership with no period is one nothing can bill, renew or expire: §7.3's grace window is measured from `current_period_end`, the member screen cannot say when it renews, and `book_class()`'s past-due allowance — `now() < coalesce(ms.current_period_end, now()) + grace` — collapses to `now() < now() + grace`, **true for ever**.

The interval is the plan's `billing_interval` × `billing_interval_count`, computed in the studio's local time and converted back so a boundary does not drift an hour across a clock change. A pack, a drop-in and a trial get no period, which is what makes the column mean something: a period present is a thing that renews.

`starts_on` and `expires_on` move to the studio's day at the same time. They were `current_date` — the SERVER's — so for a Manila studio, sixteen hours out of every twenty-four, a pack sold in the morning expired a day before it should have.

### Recording a payment against an active membership ADVANCES it

The desk taking next month's cash **is** the renewal. Creating a second membership for it would leave the member holding two, with two periods and two allowances.

**The period advances from `current_period_end`, never from today.** Paying four days early must not shorten the next month; paying four days late must not move the anniversary for ever. The billing day a member agreed to is the one they keep.

A payment so late that one interval forward is still in the past leaves the membership past due, and says so. That is correct rather than awkward: a member two months behind owes two months, the desk records the second payment, and the list goes on showing them until they are square. Rolling to today instead would forgive the arrears and drift the billing day in the same stroke.

A payment for a **different** plan is a plan change and still creates a membership. A pack is never a renewal. A frozen membership is not renewed by taking cash — §7.4 is its own decision.

### A lapsed period becomes `past_due`, nightly

`sweep_membership_periods()` at 03:20. **Scoped to memberships with no Stripe subscription**, which is the whole gap: a Connect subscription rolls its own period forward and says `past_due` through `invoice.payment_failed`, and sweeping those here would mark a member overdue for the minutes between a successful renewal and its webhook arriving. §7.3 is untouched and does the rest.

### The list of who owes

`memberships_due()` and `/due`, **front desk and up** — §9 reads their "Payments" as taking payment, and the desk is who chases and records one. Overdue first, with what they owe, how long it has been, and a button that takes the money from that row.

What each owes is the membership's own `price_cents`, never the plan's. §7.1 snapshots the price at purchase precisely so an edit cannot reprice anybody already on it, and a chase list quoting today's price would undo that at the counter.

Subscription-backed, frozen, cancelled and expired memberships are all absent. "No recurring plans at all" and "everybody is paid up" are separate states, because a screen that cannot tell them apart says "nobody owes you anything" to a studio whose memberships are all on Stripe — true, and useless.

### Why Decision 16's own test did not catch the missing period

It **does** use a recurring plan, and it compares the cash membership and the Stripe membership field for field. Both were null. The Stripe half is driven by a `checkout.session.completed`, whose object carries no `current_period_*`; those arrive in a later subscription event the test never sent. The assertion held because **neither side did the thing**.

Two implementations agreeing proves nothing when both are wrong. It is "a guard that never fires looks exactly like a guard that passes" wearing an equality check, and the comparison now has to be comparing something.

### Open, not decided here

A member may hold two active recurring memberships on different plans, and both appear on the due list owing separately. Whether selling plan B should supersede plan A is a plan-change decision nobody has made; the list reports what the data says.

**Where:** migration 095, `test/manual_payments_test.sql`, `/due`. **Status:** settled.

---
## 22 — Guarantee tiers, cutoff evaluation and instructor pay, overturning part of Decision 10

Optional per studio, off by default. A studio that never sets a tier sees no change anywhere.

**This overturns part of Decision 10**, which put anything resolving to money owed in Wave 3 and drew the boundary at *"classes taught multiplied by anything is compensation."* That test is exactly why the overturn is necessary rather than convenient: a guarantee tier creates an obligation the studio owes **whether or not the class runs**, and an obligation nobody computes is one that gets settled from memory. Decision 10 has been amended in place rather than quietly contradicted.

### Three tiers, extending Decision 21 rather than sitting beside it

`core` runs at or above its minimum and, if it does not, does not run and the instructor is paid a holding percentage. `flex` is Decision 21's existing behaviour exactly — runs at its minimum, no pay and no obligation if unmet. `always` runs unconditionally.

**Core is the default, and that is what makes "sees no change" true.** At `core_min_bookings` 1 a class with one booking commits and pays in full, which is what happens today. The `flex` boolean stays as the compatibility surface underneath the tier and is still read: a resolver that looked only at the new column would silently demote every Decision 21 row to core, turning a class that cancels for want of one booking into a class somebody is paid a holding rate for.

**Two switches, not one.** `flex_enabled` governs flex and `guarantees_enabled` governs core. A studio already running flex keeps working without opting into anything and — the half that matters more — does not silently acquire core evaluation on every other class it runs.

### Two cutoff shapes, deliberately not collapsed

Core measures backwards from the class, because it mirrors the cancellation window and the headcount is effectively final by then. Flex is a wall-clock time the evening before, so an instructor can plan a whole day at once. Both existed in Decision 21; each tier now has its own.

**`always` commits at the class's start time.** It has no minimum, but it needs a terminal transition, because that is where pay is written and locked — otherwise it would be the only tier nobody is ever paid for. Nothing in this codebase moves a class to `completed`; only the demo generator and the seed ever write that value.

### Committed is terminal

A later cancellation never un-commits and never changes what is owed. `booked_at_cutoff` is snapshotted at that moment and pay is calculated from it, never from attendance, so a no-show does not reduce what an instructor is owed for a class they turned up and taught.

#### Amendment (Decision 32) — the paid headcount is `greatest(booked_at_cutoff, booked_at_start)`

The paragraph above computes per-head pay and the full-house bonus from `booked_at_cutoff` alone — the count snapshotted when the class committed. That is amended: **per-head pay and the full-house bonus use `greatest(booked_at_cutoff, booked_at_start)`**, the booked count at the pay cutoff and the booked count snapshotted at the class's start.

**Why the cutoff count alone is wrong.** The booking cutoff sits closer to start than the 12-hour pay cutoff, so a member can book after the pay cutoff and attend, adding a body the pay record never saw; on a nearly-full class that member can take the last seat and never trigger the full-house bonus the instructor earned by teaching a full room. The cutoff snapshot was the instructor's *promise*, not the final roster.

**What it keeps.** Decision 22 stands: pay is from bookings, never attendance; a no-show keeps their seat and counts; `committed_at` is still terminal and still stamped at the cutoff. It adds two guarantees: the instructor **never earns less than the cutoff promised** (`greatest` only raises), and a **late cancellation after the cutoff cannot reduce pay** (a lower start count loses to the cutoff).

**The mechanism, because the record is written before start.** For core and flex the pay record is written at the cutoff, before start, so `booked_at_start` does not exist at write time. `sweep_commitments` — the same background pass that commits `always` classes at their start — stamps `booked_at_start` at start (counting the same statuses `evaluate_commitment` counts) and trues up the OPEN-period record from the greater-of. A **CLOSED period is never re-touched** — it is already paid; the difference is written as an adjustment in the next open period (Decision 22's correction mechanism), naming the class and "late bookings after cutoff". `always` needs no snapshot: it commits at start, so its `booked_at_cutoff` is already the start count. **This is a compute change, not a rate change** — no new rate version; the rates are unchanged and only the headcount fed to the formula moves. Existing closed-period records stay exactly as computed. The statement and the CSV carry a "2 at cutoff, 3 at start" note when the start count raised the amount. (Migration 160, `compute_class_pay_run`, `snapshot_start_headcount`, `sweep_commitments`; `test/guarantee_pay_test.sql`.)

**`not_running` is not a new status.** It is `cancelled` with `cancellation_cause = 'unmet_minimum'`. A fourth `occurrence_status` would mean teaching thirty-odd places that filter on `cancelled` about a second way for a class to be off.

**Members are never notified of `not_running`.** By definition there are fewer than the minimum and usually none at all; §3.2 tells whoever is actually booked. Instructor notifications are batched — one digest per evaluation run, deduped on the SET of classes decided, so a retry sends nothing and a genuinely later batch still sends.

### Why a cancellation was ordered matters, and lives in the data

`studio_fault` pays base, `force_majeure` pays nothing, `closure` pays nothing **by default with a per-closure override**: a Christmas closure announced in October is not something anyone should be paid for, and a brownout on the day is. The override is stamped on the occurrence rather than resolved at pay time, because reopening a period deletes the closure row and leaves the cancelled classes cancelled.

### Pay

Rates are **versioned with an effective date** and a version is immutable; changing a rate means adding the next one. The amount is written **once**, at the terminal transition, with the version used stored on the record — never recomputed on read. A **closed period is immutable** and corrections are adjustment lines in the next open one.

`full_house_bonus` is its own field rather than a steeper final rung, and keys off the class's actual capacity, which varies by room. `private`, `duo` and `trio` rates **replace** the base-plus-ladder calculation entirely and trigger on a **marked class type**, never on headcount: a group class with two people booked is an underfilled group class, not a duo.

`pay_model` is an enum carrying one value. Adding one to a payroll system that already has closed periods and live records is the expensive version.

### Conversion bonus

Attributed to the instructor of the member's **first ever class**, not their most recent — last-class attribution rewards whoever was teaching on the day a card went through, which is close to random. One per member ever, enforced by a unique index. Fired from the membership insert, which is where `activate_purchase()` puts both Stripe and manual payments, because hooking a Stripe checkout would pay nothing at a studio taking cash. A refund claws it back as an adjustment in the next open period.

### Two questions the brief asked, answered

**Peak allowance.** Credits and infractions are already correct on the studio-release path. The seam is a typed `bookings.release_reason` written by a trigger — so it catches every writer, not just `cancel_booking()` — and stamped only when still null, which is the idempotency allowance restoration will need. When allowance arrives it is added inside that trigger for `studio_released` only, and history is repaired by backfilling on the same value.

**Substitutions.** Whoever is `instructor_id` at the cutoff is on the pay record, and the record carries its own copy so a later swap cannot rewrite who was paid. If the swap is not recorded before the cutoff, the notification has gone to the wrong person and the pay record names them; neither can be undone by an edit, so the correction is an **adjustment pair in the next open period** — negative to one, positive to the other, both referencing the occurrence.

**Multi-instructor classes are out of scope.** One `instructor_id`, one pay record. No array, no join table, no "primary" flag for a later feature to reinterpret.

**Where:** migrations 079–085. **Status:** settled.

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

### Amendment — the member who has booked is told (Deanna, 30 Sep 2026)

Decision 21 said members see nothing about flex. That stands for the SCHEDULE LIST — no badge, no count, no "needs one more", never a minimum or a headcount shown to a member anywhere. It is amended for the member who has already booked: a booking on a flex class is shown and emailed as "waiting for confirmation by <deadline>", and at the deadline the member is told the outcome either way. Members are never told why (no minimums, no numbers, no "not enough people"); the language is always about THEIR BOOKING being confirmed or not confirmed. The member queries therefore return, for a flex class not yet decided, only "pending until <deadline>" — a deliberate, member-safe widening of "the column is never asked for". Once confirmed, the class is an ordinary class everywhere. Deanna, 30 Sep 2026.

**The deadline is a shared value.** `flex_deadline_for(occurrence)` returns `(deadline_at, mode)` — `occurrence_guarantee_run(occ).cutoff_at`/`cutoff_shape`, the exact time the sweep acts on, so the time promised is the time acted on. Member-guarded (the caller holds a booking on the occurrence, or it is bookable to them, coalesce-null-safe PT403 otherwise) with a `flex_deadline_for_run` twin for internal callers. Member reads (`member_bootstrap`, the class-detail loader, My bookings, Home's next-class card) gain `booking_pending` (flex AND `committed_at is null` AND scheduled) and `pending_until` (from the `_run` twin) — nothing else: no `flex`, no minimum, no counts, no reason.

**Member-facing copy** (the only place a member meets flex): class page before booking — *"Bookings for this class are confirmed by {time} the evening before."* / *"Bookings for this class are confirmed {hours} hours before it starts."*; the Book button becomes *"Waiting for confirmation · by {deadline_short}"* (still tappable, still cancellable); the booking email replaces `booking_confirmed`'s body for this case — *"You'll receive a confirmation of your booking by {deadline}. Nothing else to do for now."* (same .ics). At the deadline, `flex_booking_confirmed` (*"{class} on {day} is confirmed — see you at {time}."*) or `flex_booking_not_confirmed` (*"…wasn't confirmed this time. Your credit is back… Here are the next ones with space: …"*) — the latter replaces `class_cancelled` for `cancellation_cause = 'unmet_minimum'` only; the §3.2 credit-back path is unchanged. Instructor `flex_confirmed`/`flex_cancelled` unchanged. **Core/always classes: nothing changes anywhere.**

### The deadline

A pg_cron sweep every fifteen minutes, per studio, in studio-local time. Fifteen and not sixty for the same reason as the Morning Brief: the deadline is a local time and studios span zones, and a coach finding out at 20:59 whether to come in tomorrow is what this exists to prevent.

**Idempotency is the occurrence's own state, not the `job_runs` claim.** A decided class is confirmed or cancelled and is never pending again. That matters because the hours-before mode has a decision point at every hour of the day, and a once-a-day claim would answer only the first of them; `job_runs` records the pass and counts attempts rather than gating it.

- Confirming is **silent** — nothing changes from the member's view, because nothing about the class was ever different.
- Cancelling goes through `cancel_occurrence()`, the §3.2 path.
- **The instructor is told either way.** A coach needs to know whether to come in, and that is the whole point of a deadline.
- **Once confirmed it runs.** `flex_confirmed_at` is a latch: a cancellation afterwards drops the headcount below the minimum and changes nothing.

### Reporting

`flex_report()` gives flex fill against core fill, per series. **Fill is measured on the classes that RAN** — a cancelled class has no fill rate, and averaging its zero in would make flex look emptier than it is and argue against the very slots that are working. A flex slot filling as well as the core one beside it has earned core status; that is the number this is for.
