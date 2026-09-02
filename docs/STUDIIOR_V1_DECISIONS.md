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
- **An approved instructor withdraws.** The class returns to `open`, staff are notified, and it is loud — the notification carries how many members are booked, because "nobody is teaching this" and "nobody is teaching this and eleven people are coming" are different emergencies. This is the worst state the system can be in and the product should behave like it.
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
