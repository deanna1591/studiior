# Studiior

Multi-tenant SaaS for boutique fitness studios (Pilates, yoga, barre). Supabase + Next.js. Six-month V1, public launch 2 March 2027, ten design partners first.

Tenant one is Reform Collective, the founder's own studio. **Its data is production data.** Treat member PII accordingly from day one.

---

## Read before writing code

| File | What it governs |
|---|---|
| `docs/STUDIIOR_PRODUCT_BIBLE.md` | The source of truth. Vision, UX and per-chapter MVP scope. Above everything below. |
| `docs/STUDIIOR_V1_DECISIONS.md` | Settled decisions. Canonical. Code that contradicts it is wrong. |
| `docs/STUDIIOR_V1_DATA_MODEL.md` | Every table, column, index, RLS approach, concurrency rules |
| `docs/STUDIIOR_V1_BUSINESS_RULES.md` | Booking, cancellation, waitlist, credits, memberships, challenges, AI |
| `docs/STUDIIOR_V1_PERMISSIONS.md` | Five roles against every action. Becomes RLS policies directly. |

`docs/STUDIIOR_PRODUCT_BIBLE.md` governs scope above all of these. Read it before arguing about what is in V1.

**Its chapter numbers are not what this file used to claim.** There is no "Chapter 8's seven modules" and no "Chapter 7 exclusion list": Ch. 7 is the Booking Engine, Ch. 8 is Memberships & Billing, and Ch. 9 and Ch. 20 do not exist at all. Scope lives in a per-chapter **MVP Scope** section — Ch. 4 (dashboard), Ch. 5 (calendar), 6.23 (CRM), Ch. 7 (booking), 8.18 (billing), Ch. 10 (community), Ch. 12 (analytics) — each splitting Phase 1 / Phase 2 / Phase 3. Volumes 1–13 at the top are an outline of what the Bible will contain, not content; only chapters 1, 4, 5, 6, 7, 8, 10, 12, 16 and 19 are written.

The seven modules — Scheduling & Booking · Member CRM · Memberships & Payments · Your Member App · AI Morning Brief · Challenges · Reports — are **this project's narrowing** of the Bible, not a quotation from it. They are a defensible six-month cut. Where they and the Bible disagree, say so out loud rather than picking silently. **Known disagreement:** Ch. 10 puts a community feed, reactions, announcements and friend connections in launch scope; this project excludes them (`docs/STUDIIOR_V1_DECISIONS.md`, "Excluded from V1"). Unresolved.

---

## Current state

Seventy-six migrations, applying clean from `supabase db reset`:

- **001** schema: 47 tables, 110 RLS policies, grants for `authenticated` and `service_role`
- **002** `book_class()`: the booking transaction — occurrence locked `for update`, §2.1 eligibility gate in order with a specific reason code per failure, §2.2 payment source resolution, waitlist, booking + `credit_ledger` + `booked_count` in one transaction
- **003** `bookings.override_reason` / `overridden_rules` (§2.3 visibility), and `p_payment_source` so §2.4 comp bookings are reachable
- **004** `studio_by_slug()` — the pre-login lookup behind `{slug}.studiior.app`, and the only function `anon` may execute
- **005** comment-only: corrects migration 001 §16, which says there is no pre-login surface in V1. There is exactly one, and §16 also missed that PostgreSQL grants EXECUTE to `PUBLIC` by default
- **006** revokes `PUBLIC` execute on the auth and RLS helpers and changes the default for future functions, so §16's intent is actually true
- **007** the §8 check-in window as a trigger, with `studio_settings.checkin_window_enforced` as the documented way off
- **008** `plan_templates` (studio_id null = system) with six system templates, and a trigger refusing to delete a plan that has members on it
- **009** CHECK constraints making the plan-type field rules real (a pack cannot bill monthly, a subscription cannot expire), and one active plan per name per studio
- **010** Decision 12: `credits` is class-pack only, `credits_per_period` is recurring-only and null there means unlimited. The fifth constraint 009 left open
- **011** closes the anon RPC surface for real (006 revoked from `PUBLIC`, but hosted grants `anon` explicitly — see the rule below), makes trigger functions callable by nobody, and pins `search_path` on the five that predate the convention
- **012** onboarding: `platform_admins`, `studio_invites` (hashed, single-use), `studios.status = 'provisioning'`, `setup_progress`, and `accept_studio_invite()` — account, owner row and status flip in one transaction
- **013** revokes execute on `rls_auto_enable()`, the Supabase-installed event trigger function behind `ensure_rls`. Guarded, because it exists only on hosted — which is why 011 missed it
- **014** `revoke execute on all functions in schema public from anon`, then re-grants the three pre-login surfaces. Also moves `btree_gist` out of `public` — the only way its 188 index internals could leave the API-exposed schema, since `postgres` cannot revoke grants `supabase_admin` made
- **015** `validate_iana_timezone()` on `studios` and `locations` — a zone not in `pg_timezone_names` cannot be stored by any writer. Plus ISO shape checks on currency and country, and `provision_studio()` fixed forward with `invalid_timezone` / `invalid_currency` / `invalid_country`
- **016** the importer's schema half: nullable `check_ins.occurrence_id` / `booking_id` so an imported visit can exist without a class, an `import_id` marker, `check_ins_booked_or_imported` (a check-in is either an import or has both a booking and an occurrence), and `recompute_member_stats()`
- **017** demo data: `is_demo` on twelve tables, `generate_demo_data()` and `purge_demo_data()`, platform-admin only. Every id is derived from the studio id, so two runs produce identical data
- **018** Decision 14 health score: `member_health()` (pure), the cache on `members`, `refresh_studio_health()` for the nightly pass, and a trigger recomputing on check-in. Includes the `new` band for members joined under 14 days, per the amendment recorded in Decision 14
- **019** the importer's function half: `import_dry_run()`, `import_commit()`, `import_rollback()`. Also `import_member_status()` / `import_membership_status()`, which both halves share — a file saying "Active" against a lowercase enum must fail at review, not inside the commit transaction the review just promised was safe
- **021** the member journey timeline: `rebuild_member_timeline()` / `rebuild_studio_timeline()`. Data model §4 asks for one writer that is testable and replayable, so every event is *derived* from its source and the whole thing can be dropped and rebuilt without drifting. `booked` is deliberately not emitted — it tells every attended class twice and every cancelled one twice
- **076** converging hosted with the files, **a third time**: `generate_occurrences`, `schedule_range`, `flex_pending`, `flex_report` and `sweep_flex_decisions` re-issued from 075's file. Found by `scripts/check-hosted-drift.sh` on the first run after it was fixed — see the rule below
- **075** Decision 21, flex classes: `flex` and `minimum_bookings` on series and occurrences, a per-studio deadline in two shapes, `sweep_flex_decisions()` every fifteen minutes, `flex_pending()`, `flex_report()`, and `flex_confirmed_at` as a latch
- **074** studio closures: `studio_closures`, `studio_closed_at()` as the one predicate, `cancel_occurrence()` — the first caller `queue_occurrence_cancelled()` has ever had — `close_studio()` two-step, `reopen_studio()` which is not an undo, and a brief insight for a class sitting on a day the studio is shut
- **073** the member invite is finally SENT: `invite_member()`, `invite_members_bulk()` and `member_invite_status()`, a `member_invite` template that does not claim there is an app to download, and the two always-send lists learning it
- **072** `next_class_day()` — an empty calendar can finally say where the timetable actually is, plus a date picker, after "the calendar is empty" turned out to be a correct empty day nobody could navigate off
- **071** converging hosted with the files after **two migrations were edited in place once already applied** — `schedule_range` was raising on every call in production, and `purge_demo_data` had never gained its confirmation step there
- **070** `schedule_range()` and `studio_today()` — the calendar asks for a range of the STUDIO's days and the day boundary is resolved in the database, after it rendered an empty grid for every day
- **069** `reconcile_booked_counts()` — the nightly recount `booked_count` was assumed to already have and never had, plus `occurrence_seats_taken()` as the one definition of what the cache is a cache of
- **068** the occurrence horizon becomes days, defaults to 60, gains a screen, and finally does something when it SHORTENS: `set_occurrence_horizon()` two-step, deleting rather than cancelling and refusing outright over a booking
- **067** weekly confirmation: one press for the whole week, per-class cover beside it, and an ask/remind/escalate cycle whose every day and window is a per-studio column
- **066** an instructor submits their own month and staff approve it: `availability_submissions`, `approval_status` defaulting to approved so nothing existing is invalidated, and the monthly cycle keyed on `availability_due_day`
- **065** the commitment stops scheduling anybody: assignment ranks by fewest classes that week and nothing else, the availability window stops being defaulted from the agreement, and `commitment_report()` gives the measurement the table exists for
- **064** `class_series` finally has a form, and editing one stops being destructive: `update_series()` two-step, `rrule_last_date()` folding COUNT into a date, `series_rule_matches()`, `generate_occurrences()` gaining a `p_from`, and the setup checklist learning qualifications, availability and commitments
- **063** a demo row a human edits becomes real, and the purge asks first: `tg_promote_edited_demo_row()` on the seven tables with an edit form, and `purge_demo_data(studio_id, confirm)` refusing until confirmed
- **062** `purge_demo_data` destroyed real data on production. The function only ever deleted `is_demo` rows; `class_occurrences.series_id -> class_series` is ON DELETE CASCADE, so deleting a demo series took every occurrence of it whatever the occurrence's own flag said. Detaches real children from demo parents first, marks what the generator caused, and **counts every non-demo row before and after, raising if one has gone**
- **061** the assignment engine: `assign_instructors_run()` behind the manager-up `assign_instructors()`, `instructor_valid_on()`, `class_occurrences.assigned_by`, and the validity gate added to `move_occurrence()`
- **060** `instructor_class_types` — who can teach what, written from either side, with `instructor_qualified()`
- **059** the member screen's three read-only sections get writers, and documents get built: `rebuild_timeline_rows()` (the derivation, unguarded) behind the guarded `rebuild_member_timeline()`, triggers on the four source tables, `backfill_all_timelines()`, `member_goal_progress()`, `member_documents` + a private bucket, and `record_document()` which sets `members.waiver_signed_at`
- **058** archive and delete for class types, rooms and instructors: `archive_impact()`, `archive_record()` two-step, `restore_record()`, three delete guards, and a trigger making `archive_record()` the only way to reach `status = 'archived'`
- **057** data model §5's occurrence generation, specified since the beginning and never built: `generate_occurrences(series_id)`, a nightly `generate_all_occurrences()` claiming per studio in `job_runs`, and materialise-on-create/edit as a trigger. Adds `class_occurrences.series_slot_at` and `studio_settings.occurrence_horizon_months`, and makes a move set `is_exception`, which nothing had ever done
- **056** guards three `SECURITY DEFINER` reads that had none: `instructor_availability_week` and `instructor_weekly_load` from 053, and `instructor_available_at` — which has carried the fault since **047**. Manager-up of that instructor's studio, or the instructor themselves
- **055** the brief learns two Decision 18 types: `cover_unanswered`, ranked **0** inside the escalation window — above `unstaffed_class`, which 17 already put above a declined card — and `commitment_shortfall`, the reason `instructor_commitments` exists at all
- **054** cover requests: `request_cover`, `approve_cover_request` (assign a named replacement, or open it as a Decision 17 shift), `decline`, `withdraw`, the five-minute escalation sweep, five templates, and the first caller `queue_substitution()` has ever had. Also scopes `send_due_notifications()` to `channel = 'email'` — it claimed every scheduled row and posted it to Resend, so the first push row anyone queued would have been delivered as an email
- **053** Decision 18's schema: `instructor_commitments`, `set_instructor_availability()` (a whole week, replaced in one call), `set_availability_exception()`, `instructor_availability_week()` and `instructor_weekly_load()`
- **052** `staff_bootstrap()` — the same collapse for the staff app: the staff row, the studio, its primary location, onboarding state, the platform-admin flag and billing state in one request instead of five in sequence
- **051** `member_bootstrap(slug)` — the member context, the studio, its member-facing settings, its billing state and any live offer in ONE request. Replaced four that had to run in sequence
- **050** what a move costs: the instructor constraint becomes DEFERRABLE so a swap is possible, a significant move grants every booked member a free cancellation (finally implementing `sub_late_free_cancel`, declared in 001 and read by nothing), an undo window withdraws the unsent email, and a blocked move names the class in the way
- **049** the Morning Brief learns `unstaffed_class` — an open shift with members booked, ranked above a failed card because a declined card can wait until Thursday and a 7am class cannot. Also fixes a latent `text[] || text || text` bug in `brief_summary()` that appended an empty part
- **048** applications: `apply_for_shift`, `approve_shift_application` (auto-declines the rest in the same transaction), `decline`, `withdraw_from_shift`, five templates, and `class_moved` for members whose class is rescheduled
- **047** Decision 17's schema — `staffing_state`, `shift_applications`, the first GiST exclusion constraints in the codebase, and `move_occurrence()`, the only thing that moves a class
- **046** the platform webhook — a SECOND endpoint with a SECOND secret, refusing anything carrying an `account` — plus the grace warnings, `sweep_platform_billing()` on a daily cron, and `render_notification()` extended to address a person at the studio rather than only a member
- **045** what a locked studio cannot do: `book_class`, `resolve_checkin_code`, `import_commit` and `record_manual_payment`. Deliberately NOT `cancel_booking`, and not any read
- **044** `platform_subscriptions` — Studiior charging the studio, $79/month USD, thirty-day trial stamped by a trigger on `studios` as well as by `provision_studio()`, plus `studio_is_locked()`, `studio_billing_state()` and `extend_trial()`
- **043** `choose_pay_at_desk()` — a member at a studio that HAS a provider can still say they will pay at the counter. Confirms the held seat and leaves a pending payment for the desk
- **042** `studio_setup_state()` gains an `optional` flag per item, so a checklist can say "nice to have" rather than nagging forever
- **041** Stripe stops being the foundation and becomes the first adapter: its handlers call `activate_purchase()` and `confirm_dropin_payment()` instead of granting anything themselves, and every row it writes is stamped `provider = 'stripe'`
- **040** Decision 16: `payments.provider`, `method`, `reference`, `recorded_by`; `record_manual_payment()` for front desk and up; `record_refund()` for managers and up; and the two shared grant functions both providers go through
- **039** the setup checklist stops taking a studio's word for Stripe: `connect_stripe` derived from `stripe_account_id` rather than from the stub's stored flag, which was the one item in that checklist that could go stale
- **038** Stripe Connect Standard: OAuth with a single-use state, hosted Checkout on the connected account, `stripe_webhook()` and six handlers. §7.3's `invoice.payment_failed` finally calls `queue_payment_failed()`, which migration 031 left with no caller
- **037** a drop-in holds its seat while the member pays — `book_class()` and `cancel_booking()` replaced from their live definitions, plus `sweep_unpaid_dropins()` on pg_cron
- **036** `booking_status = 'pending_payment'` and `studio_settings.dropin_payment_window_minutes`. Its own migration because a new enum value cannot be USED in the transaction that adds it
- **035** a member's own profile — `preferred_name`, a private `member-avatars` bucket whose write policy keys on the member's own id, `class_types.image_url`, a class-type image policy for managers (029's is owner-only, and Permissions §4 gives class types to managers too), and `guard_member_self_update()`. That trigger is the point: `members_self_update` had no column restriction, so a member could sign her own waiver and promote herself past the §2.1 gate
- **034** the four faults in a real delivered booking confirmation: a reply-to (`studios.contact_email`, new and nullable — absent means no header rather than a fake one), the room folded into the sentence instead of stranded in its own paragraph, a footer of contact details and an email-settings link instead of the studio name repeated under a rule, and an accent that falls back to neutral grey rather than to Studiior's lime
- **033** closes the notification functions. Migration 030 revoked them from `PUBLIC`, which on hosted leaves the `authenticated` grant untouched — so any signed-in member of any studio could call `notification_api_key()` and read the Resend key, `send_via_resend()` to send arbitrary mail from our domain, or `render_notification()` to read another tenant's email in cleartext. Also closes 031's three trigger functions, which came out **anon**-callable
- **031** wires §12's events with triggers rather than call sites — a booking is made from four different places and a notification that depends on each caller remembering is one the next caller will miss. Also skips demo members, and an hourly credit-expiry sweep because "seven days before" is a date in the studio's timezone, not an event
- **032** `create extension if not exists pg_net`, which had been enabled by hand on hosted and appeared in no migration — a fresh project applied all thirty-one and then failed a minute later, inside cron, with `schema "net" does not exist`. Also narrows two search_paths back to `public`
- **030** notification delivery, email only: `queue_notification()` checks preferences at queue time, `send_due_notifications()` claims with `for update skip locked` and posts through a transport behind a config row, `reconcile_notification_sends()` turns the provider's answer into sent or failed. pg_cron every minute for both
- **029** studio branding for the member app: `theme_preset` (warm/clean/calm/bold), a shape-checked `accent_color`, a `studio-branding` storage bucket whose write policy keys on the studio id in the first path segment, and `studio_by_slug()` fixed forward to carry the branding — the login screen and the tab title are both branded before anyone signs in
- **028** Decision 15: §2.1 rule 5 passes `lead` as well as `active`, and a second guard after §2.2 refuses a lead resolving to anything but `drop_in`. Replaced `book_class()` forward **from the live definition**, not from 002's text — 003 added a fifth parameter, so re-issuing 002's four-argument signature creates a second overload and every call fails as ambiguous
- **027** member accounts: `member_invites` (hashed, single-use, one live per member), `claim_member_account()` for the invite path, and `claim_member_by_email()` for self-signup — which refuses until `auth.users.email_confirmed_at` is set
- **025** the member app's missing half: `occ_member_own_read` (a member may read a class at any status if they have a booking or check-in for it), `rooms_member_read`, `studio_member_settings()`, the rotating check-in code, `cancel_booking()` per §3.1, and `respond_to_offer()`. Written after asking a real member session what it returns, not after designing screens
- **024** the clock behind the brief: `is_service_context()`, `run_due_morning_briefs()`, and a pg_cron job every 15 minutes. `studios_due_for_brief()` had existed since 023 with nothing calling it, so no brief ever generated on its own
- **023** the Morning Brief: `insight_config` (every §11 threshold as a row a studio can move), `generate_morning_brief()`, `brief_summary()`, `studios_due_for_brief()` and `set_insight_status()`. Writes `ai_insights` and `morning_briefs`, which had existed since 001 with nothing writing them. No model is called and `model` / `prompt_version` stay null — a row naming a model it never saw would be worse than an empty column
- **022** `messages` and `message_templates`: one person writing to one member, per Permissions §12 — owner, manager and front desk, never instructors. Nothing sends. `send_message()` moves a draft to `queued` and stops, so a transport becomes one adapter reading queued rows rather than a refactor. `message_draft_for()` composes from the band's reason, one draft per reason, out of a table a studio can later edit
- **020** `is_manager_up()` and `is_desk_up()` return false rather than null for a caller who is staff of no studio. `auth_role_in()` gives null, `null in (...)` is null, and every guard in the codebase is written `if not is_manager_up(x) then raise` — which does nothing against a null. Harmless in the ~110 policies that use these (a policy denies on null); a hole in every SECURITY DEFINER function that used them as a gate. See the rule below

Twenty-nine suites, **1,363 assertions**, all passing from a clean `db reset`:

| Suite | Asserts | Covers |
|---|---|---|
| `test/rls_test.sql` | 36 | tenant isolation, role boundaries, restricted views |
| `test/book_class_test.sql` | 69 | authorisation, gate reason codes, payment resolution, overrides, comp, and migration 069's reconcile: a no-show keeps their seat, a hand-written booking drifts the cache and the recount fixes it, a dry run writes nothing, and a studio that only ever used book_class has no drift at all |
| `test/booking_concurrency_test.sql` | 20 | 50 simultaneous bookings against a 10-seat class |
| `test/checkin_window_test.sql` | 11 | §8 check-in window bounds, the settings that move them, the escape hatch |
| `test/plan_management_test.sql` | 56 | Permissions §9 on plans and templates, the delete guard, price snapshotting |
| `test/onboarding_test.sql` | 71 | platform-admin boundary, invite single-use and expiry, atomic acceptance, derived checklist, the stranded-user guards |
| `test/health_score_test.sql` | 59 | Decision 14's five signals in priority order, every band including `new` and `insufficient_history`, reasons carrying real numbers |
| `test/notifications_test.sql` | 55 | preferences suppress at queue time, a duplicate dedupe key is refused, a missing API key fails the row and not the cron, a second worker run cannot re-send a claimed one, no internal is executable by `authenticated` or `anon`, and a rendered email carries a reply-to, a folded room and a neutral accent |
| `test/member_accounts_test.sql` | 65 | an unverified email cannot claim an existing member, a used or expired token fails, one login holds two memberships without either seeing the other, a lead books drop-in only; and migration 073's invites — inviting queues exactly one notification, a resend sends a second email and kills the first link, a claimed invite cannot be reused, the mail carries the studio's name and accent and never Studiior's lime, and a member with a blank email is refused by name rather than failing silently |
| `test/member_app_test.sql` | 32 | history joins to real classes while someone else's past class stays hidden, the code rotates and only the desk resolves it, cancelling returns or consumes the credit and always frees the seat |
| `test/brief_schedule_test.sql` | 32 | a studio past its send time is picked up and one that is not is skipped, a second run the same day is a no-op, a half-finished run retries, and an authenticated caller with no JWT is still refused |
| `test/brief_test.sql` | 25 | the cap holds at five when twelve qualify, a dismissed subject stays gone seven days and comes back on the eighth, every `action_payload` href matches a route the app serves, retention_risk agrees with the band |
| `test/messages_test.sql` | 34 | one draft per reason, sending queues and never sends, the journey learns once, §12 including an instructor and a stranger |
| `test/timeline_test.sql` | 20 | derivation matches source, rebuilding twice does not double, a stranger and a front desk are both refused |
| `test/scheduling_test.sql` | 46 | a room cannot hold two classes and an instructor cannot teach two, a cancelled class stops holding its room, a move with members booked refuses until confirmed and then emails them, two instructors apply and approving one auto-declines the other, and withdrawing returns the class to open |
| `test/platform_billing_test.sql` | 39 | a studio in grace still books and takes money, past grace both apps lock, cancellation survives lockout, paying reinstates with row counts proving nothing was lost, and neither webhook endpoint accepts the other's events |
| `test/manual_payments_test.sql` | 32 | a studio with no provider sells a membership, grants a pack and takes a drop-in; a cash membership and a Stripe membership are the same row; a refund takes back the credits she had left and not the ones she used; front desk sells but cannot refund |
| `test/stripe_connect_test.sql` | 38 | a forged signature is refused, an event for an unknown account is rejected rather than misattributed, a replay is a no-op, a plan price rise does not reprice existing members, a failed payment blocks new bookings while existing ones stand, and an abandoned hold is swept back to the waitlist |
| `test/cover_and_commitment_test.sql` | 80 | a week entered in one go including copy-to-days, a re-entered week replacing rather than appending, an exception surviving it, an instructor who cannot lower their own minimum, a cover request leaving the class assigned, a same-day request escalating on arrival and the sweep catching one that became urgent later, approving into an open shift landing in Decision 17's application flow, Decision 2's free cancellation on a late substitution, and a replacement with no login being reported as unreachable |
| `test/occurrence_generation_test.sql` | 95 | a series materialises on create and a second run creates nothing, an occurrence moved away from its series is not regenerated into the slot it vacated, a 07:00 class stays 07:00 across the October DST change, two studios generate in one cron run and a second run the same day claims nothing, a clashing week is reported while the other fifty-one are still created, a rule the parser does not understand cannot be saved, shortening the horizon deletes rather than cancels so lengthening it refills the calendar completely, a booking beyond the new edge refuses the whole change and names it, and a moved class, a hand-assigned one and a one-off are all kept; and the calendar's range in two timezones in one run — a 07:00 Manila class stored at 23:00 UTC the previous day is on Manila's 18th and not its 17th, Prague's same date returns Prague's class and none of Manila's; and migration 074's closures in those same two zones in one run — the generator skips a closed period and says it did, closing cancels what was already there, a partial day takes only the classes inside its hours, one studio's closure is not the other's, and reopening regenerates what was never made while leaving cancelled classes cancelled |
| `test/demo_purge_test.sql` | 36 | a real class materialised against a demo series survives the series being purged and keeps its booking, real instructors, availability, commitments, members, class types, rooms, plans and series all survive, demo data regenerates cleanly afterwards, and a second round changes nothing |
| `test/assignment_test.sql` | 41 | a November-only instructor is not a December candidate and a dated exception removes one day inside the window, a qualified-but-unavailable instructor is left open rather than assigned, six classes split three and three by fewest that week, a target of 12 wins nobody an extra class and a target of 2 costs nobody one, an expired agreement does not make somebody unschedulable, a manual assignment survives a re-run, a dry run writes nothing, and the report measures against the minimum while somebody outside the studio cannot read it at all |
| `test/qualifications_test.sql` | 13 | an unmapped instructor is qualified for nothing, re-saving replaces rather than appends, another studio's class type cannot be mapped in, and an instructor reads their own and cannot decide it |
| `test/member_records_test.sql` | 36 | a booking or check-in writes the timeline as it happens and rebuilding does not double it, the backfill covers every studio, a goal counts only visits since it was set, a waiver upload signs the member so the booking gate agrees, an instructor sees no documents at all and front desk sees everything except the medical one, and another studio's owner sees none of it |
| `test/archive_test.sql` | 56 | an archived class type, room and instructor are invisible to a member and visible to staff, deleting a referenced record is refused and names what is in the way, archiving an instructor opens her future classes and emails the managers while her past classes keep her name, a room with classes in it is blocked rather than warned, and status cannot reach 'archived' by hand |
| `test/instructor_self_service_test.sql` | 66 | a staff-entered pattern is already approved and still feeds the engine, a submitted one narrows nothing until somebody approves it, an instructor cannot approve their own, an approved month replaces the standing pattern for its days without deleting it, a pattern far under the agreed commitment is still approvable, two studios on different settings are asked and escalated on different days in ONE sweep, confirming the week confirms every class in it, asking for cover on one leaves the rest, escalation covers only the next three days, confirming late clears it silently, and nothing is ever released |
| `test/flex_test.sql` | 39 | a studio with flex off sees nothing even when its own rows carry the flag, turning a series flex reaches the classes it has already made, a class at its threshold confirms silently and one below it cancels through §3.2 with credits back and nobody marked late, zero bookings cancels and tells only the coach, an occurrence flipped to guaranteed survives the sweep, a confirmed class stays confirmed when somebody drops out, and two studios on different deadline modes are decided in ONE run |
| `test/series_test.sql` | 65 | retiming a series moves its classes instead of making a second copy of the year, a capacity change reaches the classes already on the calendar, six weeks of history keep the time they were taught at, a class somebody has dragged is left where it was put, dropping a day cancels it and putting it back restores it, dropping one somebody is booked on is refused even when confirmed, a COUNT series ends and does not slide forward every night, the series instructor does not overwrite a person's choice, and the checklist knows what "fill a month" needs |
| `test/importer_test.sql` | 58 | dry run changes nothing, commit is atomic, rollback is exact and refuses when it cannot be clean, no notifications or challenge progress from imported attendance, §5 including a caller who is staff of another studio |

`supabase/seed.sql` runs automatically on `db reset` and seeds Reform Collective as tenant one — **synthetic data only**, every address `@example.com`. One studio, one location, two rooms, four class types, three instructors, owner/manager/front-desk/instructor logins, four plans, a thirteen-class week materialised 26 weeks back and 4 weeks forward, and 30 members across six cohorts with attendance to match. The cohorts exist so the AI features have something real to read: five members drifting into `retention_risk`, four `new_member_stalled`, one `past_due` membership, four who never returned after one class. Attendance is generated from a deterministic hash rather than `random()` - but **it is not actually deterministic, and the claim that every reset produces an identical database is false.** The hash is `hashtextextended(member.id || occurrence.id, 42)`, member ids are pinned literals, and `class_occurrences.id` defaults to `gen_random_uuid()`. Half the hash input is therefore fresh on every reset: two back-to-back resets minutes apart gave 911 and 954 historical bookings, 732 and 791 check-ins. It is the same shape as the `provision_studio()` bug recorded below - a deterministic hash over a non-deterministic id - and the fix is to derive occurrence ids from (series, date) rather than to reseed the hash. Unfixed. No suite depends on it today, because every suite builds its own fixtures; a future one that read seed data would be testing a different database each run. Reform Collective is seeded with a **terracotta** accent (`#B85C38`) on Warm, deliberately not `#BEF738`: it had a null accent, so every member screen fell back to Studiior's lime and the white-label promise was invisible in every screenshot and demo - the one thing the theming work exists to prove. The seed also carries class-type descriptions that say what a class is and what to bring, and instructor bios and certifications, because the member's class detail screen shows them and an empty section there is indistinguishable from a broken query - the same trap the CRM tables sat in for months.

It also seeds the CRM tables — notes (including a `managers_only` one, so that policy has a fixture), goals, tags — and rebuilds the timeline at the end. Those three tables had existed since migration 001 with nothing ever writing to them, which meant every CRM section rendered its empty state in every environment and an empty state was indistinguishable from a broken query.

The vertical slice is built: Next.js App Router + TypeScript + Tailwind, staff app on `localhost:3000` and the member PWA on `{slug}.localhost:3000`. Staff sign in, see the week, create a class; a member signs in on the studio subdomain and books it through `book_class()`; front desk checks them in. See `docs/SLICE.md` for how to run it and which login to use for which role.

Every database call goes through a request-scoped client carrying the user's session, so RLS applies to all of it. There is no service-role client in the codebase and there should never be one — migration 004 exists because the pre-login slug lookup needed a policy, not a key.

Rooms, class types and instructors have list/create/edit screens at `/rooms`, `/class-types`, `/instructors` — Owner and Manager, per Permissions §3 and §4, enforced by the existing `*_manager_write` policies. The dashboard checklist links to all three. An instructor is a teaching record with `staff_id` null: no login, no invite.

Membership plan management is built: list, create from one of six system templates or blank, and edit, at `/plans`. Owner and Manager only — Permissions §9 — enforced by `plans_manager_write`, not by the nav.

The member importer is built, at `/imports`: upload a CSV, match its columns, see exactly what would happen, commit, and undo. Three types in dependency order — members, then memberships, then attendance — each matching on email. The split is that string work happens in TypeScript (`lib/csv.ts`: quoted commas, a date order inferred per column rather than per row, names in one field or two) and judgement happens in SQL, where the studio's existing members and plans are. Owner and Manager, per Permissions §5. Attendance import writes `check_ins` with no occurrence and fires no notification, challenge progress or achievement — importing history must not tell thirty people they have earned a streak.

Onboarding is built and invite-only: the operator provisions a studio shell at `/admin` (gated by `platform_admins`, checked in SQL), the owner accepts a single-use hashed token at `/invite/[token]`, and a three-step wizard blocks every other screen until it finishes. The dashboard checklist derives its ticks from live data rather than stored flags, so it cannot go stale. Stripe is a stub.

The staff app is redesigned: a persistent left rail (studio and location top, nav, current user bottom; a drawer below `md`, because front desk works on an iPad and a bottom bar costs roster rows), the schedule as rows defaulting to **day**, pill filters with a day/week toggle, and one banner slot ordered money → blocked members → setup → nudges, suppressed only when it would point at the screen you are on. Archivo at `wdth 112` for display, Karla for body, IBM Plex Mono with `tabular-nums` for every number that is a measurement — not phone numbers, which look like part codes in mono. No glass anywhere: over a light surface it reads as a rendering artefact, and spending the effect elsewhere would dilute the health band.

The member screen is built at `/members/[id]`, and it is where the health band lands: full width at the top with its reason as a sentence, and everything under it — attendance shape, journey, membership, credits, notes, goals, payments — is the evidence for that sentence. Names link to it from the member list and from a class roster.

The five band labels are five different sentences. `new` and `insufficient_history` both used to render as "Too early", which reads as though the member arrived at the wrong time and made two unrelated states look like one: `new` is a member with a clock running on them, and `insufficient_history` is the absence of a verdict. They are now "New" and "Not enough history", and the latter's dot is a hollow ring rather than a filled one.

The Morning Brief is built and sits above the schedule on the staff home, owners and managers only. It opens with a written sentence — *"One card has been declined; four members have drifted"* — and the items sit under it, each with the one button that does something about it. Generation is a pg_cron job, `studiior-morning-brief`, every 15 minutes: `run_due_morning_briefs()` asks `studios_due_for_brief()` who is due and generates for each. Fifteen and not sixty because `morning_brief_send_at` is per studio and studios span timezones — an hourly job delivers some briefs up to 59 minutes late, which is a brief about a morning the owner has already had. Opening the dashboard must never be what makes the brief exist, or a studio that does not log in never gets one and the day it does log in it gets a brief written at noon.

The band carries an action: **Message**, beside the hero on the member screen and on list rows for non-healthy bands only — a message link on eight healthy rows is noise attached to the rows that need nothing doing. A text link, never a filled button; the chip stays the coloured thing.

`managers_only` notes are enforced where they have to be. `notes_read` is `is_manager_up(studio_id) or not managers_only`, so a front desk session never receives the row; the screen does no filtering of its own and has no way to leak one.

**Payments on the member screen are the one place the UI shows less than RLS allows, and that is a standing disagreement, not a decision.** Permissions §9 note 18 gives front desk payment history explicitly — "individual transactions to answer a member's question" — and `payments_desk_read` implements it, so front desk can still read those rows through the API. This screen withholds the section and filters `payment` out of the journey for anyone below manager, on instruction. It is a display choice and nothing more; if it should be a boundary, §9 and the policy have to change together.

Notifications send, email only, through Resend behind a one-function adapter — swapping to SMTP is a second `send_via_*` and a changed config row. The key lives in Vault or a database setting and is never in the repo. Booking confirmations, reminders at `reminder_hours_before` and waitlist offers are wired by trigger; cancelled classes, substitutions and failed payments have tested queueing functions and no caller yet, because the screens that cause them do not exist. Staff messages from migration 022 join the same queue rather than getting their own sender, so the send button finally sends. `supabase/seed.sql` clears the queue it generates — fixture data does not email anybody.

Emails carry a reply-to and a footer worth reading: the studio's contact details, its postal address, and a link to the member's own email settings. `studios.contact_email` is new in migration 034 and **nullable, and null on every existing studio** - a studio that has not set one sends mail with no reply-to at all, which is honest, and its members' replies still go nowhere. Two gaps stay open on it: the onboarding wizard does not ask for it, and there is no general studio settings screen, so it is edited from `/branding` - the only Owner-only screen governing what members see.

Members choose what they get at `{slug}.studiior.app/settings`, which is where every footer link lands. Five switches, one per opt-outable template; the four events that always send are listed and explained rather than rendered as controls that would do nothing.

Studios brand the member app at `/branding`, owner only — four presets and one accent, with a live preview that is a real member Home rather than swatches. `brand_color` stays dead and is superseded by `accent_color`.

The member PWA reads as an app rather than a webpage, and **the tinted page wash is most of why**. Before it, white cards sat on cream paper and nothing separated them: card and page were the same value and only a hairline told them apart. The page is now `linear-gradient(170deg, var(--page-top), var(--page-bottom))` - the studio's accent at 6% over the surface, drifting **-45 degrees** round the wheel and to 10% on the way down - and the cards are the plain `--surface` with two shadows and **no border at all**. The rotation is negative because it was measured against the reference: terracotta sits at hue 18 and the target second stop is up at 310, so +25 went into orange, came out warmer at the bottom than the top, and at equal lightness was invisible.

**Nothing may set `--ink-3` on the page wash.** It is 4.59 on pure white, so any tint at all puts it under the floor: 4.37 at 5%, 4.19 at 7%. The floor on the wash is `--ink-2` (6.47 worst across 8 accents x 4 presets); `--ink-3` is legal only inside a white card, where it is 4.80. The one real instance this caught was the "Taught by" divider on the filter row, at 4.45.

**A small accent mark on a white card takes the accent's TEXT step, never its fill.** The fill is measured against the ink that sits *on* it; a card stripe, a week-strip pip or the booked ring sits *on the card*, where lime measures **1.23** and vanishes. `--lime-text` is darkened until it clears 4.5 on the surface, so as a 3:1 mark it is safe for every accent. Three things were wrong on this: `.m-stripe`, both pip renderers, and `.m-card-booked`'s ring.

**`accentRamp().text` is now derived against the page wash as well as the surface.** It used to appear only inside white cards, so clearing 4.5 on `--surface` was the whole requirement; the wash put the same colour on a tinted page and "See all" landed at **4.21**. A step that is safe on one ground and not the other is worse than no step, because nothing at the call site says which ground it is on. Worst after: 4.89 on a card, 4.51 on the wash, and **0 of 32 combinations fall back** (it was 2 of 28).

**Accent text on accent tint is not a measured pair, and it was used as one.** `--lime-text` is derived against the surface; the tint is that surface with 12% accent over it, so the same colour lands at **3.88** on it. The secondary buttons (Cancel, Join waitlist, Leave list) and the avatar initial all had it. They take `--ink` on `--accent-chip` instead - 11.42 worst.

**A hardcoded white is a Bold bug waiting.** The floating tab bar and the Week/Month control were both `rgba(255,255,255,.9x)` from the reference; on Bold the surface is dark and the ink near-white, so the inactive tab label measured **2.40** and the unselected segment **1.02**. Both take `color-mix(in srgb, var(--surface) 92%, transparent)`. The hero's Check in pill had the mirror of it - white fill with `--ink` on it, **1.09** on Bold - and takes the accent's own solid/on-solid pair, which is derived together and cannot come apart like that.

**Text over a photograph needs the scrim to make it measurable.** White over a *white* photograph needs the overlay at 0.82 or darker to clear 4.5:1, so `.m-hero-scrim` is held near-transparent to 44% - the top of the picture stays visible - then ramped to 0.90, and the type is anchored in that band. The frosted tag near the top has no such band to sit in, so it carries its own 0.82 fill rather than trusting the picture. Measured against a white photograph: title and sub 14.64, tag 11.11. Over the no-photo accent fallback, 15.06.

The **week strip** is seven white tiles rather than seven bare numerals - on the wash a plain number has nothing holding it and the row reads as a line of text. The selected day fills with the accent and takes the only glow in the app. Selected, not today, takes the fill, because the member is navigating and the filled tile has to answer "which day am I looking at"; today when unselected is the accent in text, so the two never look alike.

**Classes are horizontal cards.** The old one stacked time, name, instructor, divider, action - five bands, which is a paragraph with a button under it. This one reads left to right: a colour stripe, the time, what it is, the one thing you can do. The type ratio is what makes it scan: the time is 16px Archivo bold against 11.5px metadata, where everything used to sit between 12 and 15. The card opens the detail view and the button books, which HTML will not nest, so the link is an overlay and the action sits above it.

**The tab bar floats, and it is the second place blur is allowed.** The washed page scrolls *under* an inset pill, so there is a moving gradient and moving cards behind it to refract - the case the "no glass" rule was written against is a flush bar with the app's own flat surface behind it, which also cuts the page off with a hard line. The list carries 96px of bottom padding so nothing is ever parked underneath with no way to scroll it out. Book is the leftmost tab, ahead of Home: a member opens this app to book far more often than to look at anything else.

**The Week/Month toggle has two working halves.** Month draws the whole calendar block with the same pips and hands a tapped day back to the week view. A segmented control with a dead half is the decorative control this build refuses to draw - the same rule that keeps `challenge_opportunity` switched off. Its own reason for existing: the week strip cannot answer "when is the next Saturday class", and over a month the pips make the studio's rhythm visible at a glance.

**The reference's notification bell is deliberately absent.** Nothing in this app writes an unread count - notifications are email and there is no notification centre to open. The one thing genuinely waiting on a member, a waitlist offer, is already a badge on the Home tab where their thumb is; a bell would be a second indicator for one fact, and on the days there is no offer it would open nothing.

**An Intl field is formatted in the context of the whole option set.** `month: "numeric"` alone gives `"9"`; the same option beside a weekday and a day gives `"09"`. The month grid compared the two as text, matched on no day of any month, and rendered every cell as though it belonged to the next one. Compare numbers.

**Class detail** at `/class/[id]` shows what the list cannot: the class type's description, and the instructor's photo, bio and certifications. All three have been in the schema since migration 001 and no screen had ever displayed them, which is why a member could not tell Reformer Flow from Reformer Beginners. **No migration was needed** - `instructors_member_read` and `class_types_member_read` already exist, checked by asking a real member session rather than assuming migration 025 had left instructors staff-only. `avatar_url` is null on every seeded instructor and on a real studio's first day, so the initials fallback is the normal case and is built to look deliberate.

The member PWA is built at `{slug}.studiior.app` — five screens on a bottom tab bar: home, book, check in, history, plan. Phone-first rather than a smaller staff app: body is 15px not 14, nothing interactive is under 44px, the primary action is 56px and there is one of it. Home leads with the next class, and inside the §8 check-in window that card stops describing the class and becomes the way in. Booking and cancelling go through `book_class()` and `cancel_booking()`; a class you are in reads as a different row rather than wearing a tick.

It is branded as the studio, including the browser tab, the bookmark and the name iOS uses on a home screen — `app/member/layout.tsx` titles it from `studio_by_slug()`. The word "Studiior" appears nowhere a member can see. `brand_color` is deliberately unused: an arbitrary hex with unverified contrast driving text or fills would silently break every ratio the palette was measured for, so identity is carried by the logo and the name.

**No studio has a class photograph, and the redesign leans on them.** `class_types.image_url` exists (migration 035) and is null on every seeded class type, so the hero and the Coming-up row fall through to the derived accent gradient in every screenshot and demo. That is the honest fallback and it is built to look deliberate, but it is the same trap the terracotta accent was in: the photographic half of this design is invisible until a studio uploads something. Seeding a fake photograph would be worse than the gradient. Recorded, not fixed.

**Decision 21, flex classes: optional per studio, off by default, invisible to members.** A class is guaranteed — runs regardless of headcount, which is every class today — or flex: runs only if it reaches a minimum by a deadline. A studio that never turns it on sees no change anywhere.

**Per SERIES, because neither alternative can express what Reform Collective runs.** Phase 2 has a 07:00 flex slot beside an 08:00 core one on the same days, and SCULPT appears in both. Per class type cannot say it; per time band cannot either.

**A minimum is an integer, not a boolean.** A studio with twelve reformers may want three; Reform Collective wants one, and one booking runs as a semi-private.

**`set_series_flex()` reaches the classes already made.** `update_series()` takes every field as a parameter and adding two more would change its signature, so flex got its own writer — and it matters that it touches existing occurrences: a studio that flips a series to flex and finds nothing changes for sixty days has been given a setting that does nothing. Pending, future, still-scheduled only.

**Members see nothing, and the mechanism is that nobody asks.** `flex` is on `class_occurrences`, which the member app selects **by name** — the column is simply never in the list. No "unconfirmed", no "needs one more": telling somebody a class might not run is telling them not to bother booking it, which is the opposite of what a class one short needs.

**The night-before deadline is computed from the class's LOCAL date**, stepping back a day and pinning the time, then interpreting that back in the zone — never by subtracting an interval, which drifts an hour across a clock change. The same trap `generate_occurrences()` was written around.

**Idempotency is the occurrence's own state, not the `job_runs` claim.** A decided class is confirmed or cancelled and `flex_pending()` never returns it again. That is what makes a fifteen-minute sweep safe, and it has to be: the hours-before mode has a decision point at every hour of the day, and a once-a-day claim would answer only the first of them. `job_runs` records the pass and counts attempts rather than gating it.

**`flex_confirmed_at` is a latch and the suite proves it.** A member drops out after the deadline, the headcount falls below the minimum, and the class still runs — because the coach has already been told to come in. Removing the latch makes that class cancel, which is exactly the assertion that fails.

**Fill is measured on the classes that RAN.** A cancelled class has no fill rate, and averaging its zero into the flex figure would make flex look emptier than it is and argue against the very slots that are working. A flex slot filling as well as the core one beside it has earned core status; that is the number `flex_report()` exists for.

**A teeth check found a hollow assertion, not a bug.** "A studio with flex off has nothing pending" passed with the `flex_enabled` gate removed — because that studio had no flex rows at all. It now has a series flagged flex whose studio switch is off, so the switch is the only thing standing between it and the sweep. Reverting the gate then returns 60 pending classes.

**Studio closures are an instructor's dated exception one level up, and the two halves are different problems.** Ahead of the closure the GENERATOR must not make the classes — materialising a fortnight of Christmas classes so they can be cancelled again is a fortnight of emails nobody needed. Behind it, what is already on the calendar has to be cancelled properly.

**`queue_occurrence_cancelled()` finally has a caller.** It has existed since migration 030 with none, because nothing in the product had ever cancelled a class with people in it. `cancel_occurrence()` is Business Rules §3.2, and it goes through `cancel_booking()` per booking rather than updating rows — that function is the only code that returns a credit, and a second implementation would agree with it once. §3.2's "credits back regardless of timing" is exactly what `free_cancel_until` already means (Decision 2, migration 050), so it is set ahead of each cancellation rather than teaching `cancel_booking` a new mode. Measured on the seed: 2 classes, **12 members emailed, 8 credits returned, 0 late cancels recorded** — nobody penalised for the studio's decision.

**Three orderings, each of which is wrong the other way round.** Notify FIRST, because `queue_occurrence_cancelled()` reads the bookings that are still live and finds nobody if it runs after. Mark the occurrence cancelled SECOND, which also frees its room — both exclusion constraints are partial on `status <> 'cancelled'`. Cancel the WAITLIST before the booked seats, because `cancel_booking()` offers a freed seat to the front of the waitlist and does not check whether the class still exists: doing it the other way hands somebody an offer for a class that is off.

**Reopening is not an undo, and the screen says so in words.** A cancelled class had its members told it was off and a studio changing its mind cannot untell them. Deleting the closure stops the generator skipping those days; what comes back is the classes that were **never made**, because a cancelled row keeps its `series_slot_at` and the generator steps around it (migration 068's index). `reopen_studio()` returns `still_cancelled` so the number is on the screen rather than discovered.

**One predicate, read by four things.** `studio_closed_at()` is asked by the generator, the impact preview, the member app and the brief. A second implementation of "is this closed" would disagree about a partial day the first time anybody wrote one. Partial days overlap on TIME as well as date, so a class ending exactly as the closure begins is untouched.

**A member has to be able to tell "we're closed" from "nothing is on".** `closures_member_read` puts the row itself in reach — there is nothing on it a member may not see — and `/book` shows the studio's own words where the empty state used to say "No classes on this day". Read in the same `Promise.all` the screen already had, never a second round trip.

**The brief notices the case the closure cannot prevent.** Closing cancels what is on the calendar and the generator will not make more, so a class inside a closure arrived AFTER it — typed in by hand or dragged there. Nobody meant that and the members booked think they have a class. Ranked beside `unstaffed_class`, because it is the same shape: a room of people expecting a session that is not going to happen. **The reason is quoted as its own clause**, since folding a studio's free text into a sentence produced "closed for Closed for Christmas".

**There was no way to add a member.** `/members` listed them and `/members/[id]` showed one; every member in every environment arrived through the importer or the demo generator. `/members/new` is the walk-in at the counter: name, preferred name, email, phone, date of birth, emergency contact, address, marketing consent. **Front desk, not manager-up** — Permissions §5 gives create to Owner, Manager AND Front Desk, and `members_desk_write` already implemented it; the person at the desk is exactly who does this.

**Consent is a positive act, so the box is unticked and stays unticked.** A pre-ticked marketing box opts a walk-in into mail they never agreed to, and the copy beside it says their class emails and receipts arrive either way — because the fear that stops people ticking it is that saying no means hearing nothing.

**The invite existed and was never sent.** `member_invites` and `claim_member_account()` have been there since migration 027, and `create_member_invite()` returned a raw token to whoever called it so the screen could print a link for an operator to paste into their own mail client. That works for one member and collapses at thirty — which is precisely the moment after an import. `invite_member()` wraps the existing minter and queues the email, so there is no path that creates an invite nobody is told about; `invite_members_bulk()` does everyone without an account; `member_invite_status()` answers who has claimed, who has been asked, and **who has never been asked** — a group that could not previously be known to exist.

**The copy had to be true, and "download our app" would not have been.** There is no app. The member app is a PWA at `{slug}.studiior.app`, so the email links there and says there is nothing to download, and that adding it to the home screen is what makes it open like one. **Which home-screen steps to give depends on the phone reading them** — iOS only offers Add to Home Screen from Safari's share sheet and refuses it in Chrome, Android installs from the browser menu — and an email cannot know. `/claim/[token]` detects it on the client, renders "your phone" until it does, and shows nothing at all to somebody already reading from the home screen.

**An invite gets no email-settings link.** `render_notification()`'s always-send footer says "we always send this one — it's about your booking or your membership" and offers the preferences screen; neither is true of an invite, and the reader has no account to reach that screen with. `member_invite` gets its own footer line: *"You are getting this because Reform Collective set up your account."* A control that does nothing is worse than no control.

**The raw token sits in `notifications.payload` until sent, and that is stated rather than left to be noticed.** Only its hash is on `member_invites`; the email needs the token itself. Who can read that row: manager-up of the same studio, who can mint an invite for that member anyway, and the member — who has no account yet and whose token is dead by the time they do. It expires in fourteen days and a resend supersedes it.

**The dedupe key is the TOKEN, not the member.** Pressing the button twice on one invite must not send twice; a resend is a different link and must. Keying on the member satisfies the first and silently breaks the second — and the suite passed with resend doing nothing until reverting the key exposed that the assertion for it was missing. The test now asserts two emails and two links.

**Front desk can send an invite and cannot read the notification queue.** The first version of the test counted rows as the front-desk session and got zero, which was RLS working: §5 gives them create, `notifications_manager` is manager-up. Counted as postgres.

**`/series` has two views, and the grid is the one that answers the question a studio is actually asking.** A weekly timetable — days as columns, hours as rows, each series drawn in each of its own days. A list of thirteen rows shows thirteen rows; the same thirteen in a grid make Reform Collective's **10:00–16:00 weekday hole impossible to miss**, and that hole is why somebody opens this screen. Rows span the hours in use plus one either side, deliberately including the empty middle — cropping to the busy band is what hides the gap.

**It is the STANDING timetable and must not become a second calendar.** No instructors, no bookings, no dates. It answers "what does our week look like"; `/schedule` answers "what is actually happening", and the moment this grid grows a date the two start disagreeing. The blurb says so and links across.

**`class_types.color` has existed since migration 001 and nothing had ever read it.** Four colours on the seed, unused in every screen — the same shape as `login_image_url` and `class_types.image_url` before them. The grid colours by class type, with a key above it.

**A studio's own hex cannot be trusted behind text, so it never goes there.** The colour tints the block at **14%** and sets a 3px left stripe; the label is `--ink` on that tint. Measured across the extremes a studio could pick — including pure black — the worst is **12.43:1**, where a filled block in an arbitrary hex could promise nothing. Same rule as the member app's accent stripe. Key swatches carry a hairline, because a pale colour on a pale page is a shape that vanishes and a key that vanishes is not one.

**The three states a studio needs to notice are the three the grid marks.** No room is a dashed coral outline and the words "no room" — there is no other signal, and a series with nowhere to happen is the one that will not materialise. Ended is half-opacity with the name struck through. Ending within thirty days carries its end date. All three verified in the rendered DOM rather than by reading the markup.

**The weekly total counts classes, not series.** "15 classes a week from 13 series" — because one series on Monday, Wednesday and Friday is three classes and one row, and a studio deciding whether to add a midday class wants the first number. Each day column carries its own count under its name.

**A rule the grid cannot lay out is named rather than dropped.** Only `FREQ=WEEKLY` has a place in a week; anything else is listed under the grid with a link to it, because a series silently missing from the timetable is worse than one the screen admits it cannot draw.

**The view is remembered in a cookie, not localStorage.** The server has to know which tab to render or the page arrives as a list every time and flips after hydration — a flash on every visit for a preference that never changes.

**`class_series` had a schema for sixty-three migrations and no form, so the only rows in it anywhere were the demo generator's.** A studio could not create a recurring class through the product at all — the same shape as `instructor_availability` before Decision 18 and `timeline_events` before 059. Recurring classes are now at `/series`: list, create, edit.

**Editing a series did not fail to work — it DOUBLED the timetable, and that had to be found before anything was built.** 057's trigger only ever generates. Proved on a real series before writing a line: 52 occurrences at 07:00, change `time_of_day` to 08:00, **104 occurrences at 07:00 AND 08:00**, a year of the same class taught twice a week. And the quiet half beside it: change `capacity` from 8 to 20 and every materialised class stays on 8, which looks exactly like nothing having happened. So "the form's job is just to write the row correctly" is true of CREATE and false of EDIT; a form that wrote the row would have handed every studio a duplicated year through a button.

**§5's three modes come out as two, and the missing one is deliberate.** *This occurrence only* is `move_occurrence()` on the calendar and has existed since 047. *This and future* is `update_series()`. *Entire series* is **not offered**: a class forty people attended at 07:00 was at 07:00, and no edit to a rule makes that untrue. The form says so and defaults its effective date to tomorrow — not today, or an edit made at 18:00 retimes this morning's class.

**A retimed class MOVES, through `move_occurrence()`, and does not become an exception.** Moving is the only path that owes Decision 2's free cancellation and the `class_moved` email, and a second implementation inside the series editor would agree with it exactly once. Two triggers have to stand aside while it runs, on the `studiior.series_editing` transaction-local flag: the materialise trigger, or the `class_series` UPDATE generates against a half-applied definition and duplicates anyway; and `tg_mark_moved_as_exception`, or a fifty-two-class edit marks all fifty-two and the nightly job never touches that series again — the studio's timetable frozen by one edit. `series_slot_at` is then advanced to the new instant, or the generator finds every new slot standing empty and refills it.

**`generate_occurrences()` had to learn where to start, and finding that out was the one bug the suite caught in this work rather than in the old code.** After the moves, it regenerated TODAY at the new time beside the class the edit had deliberately left behind its effective date. It takes a `p_from` now — which meant DROPPING it and re-granting, since a default argument creates an overload rather than replacing a signature.

**Dropping a day cancels its classes; putting the day back restores them.** The cancelled row goes on holding its slot, so without the restore path a studio that removed Monday by mistake would put it back and find Monday empty for a year with no error anywhere. Only classes nobody was booked on come back — a class a member was TOLD was cancelled is not something an edit to a rule may quietly reinstate. And dropping a day somebody IS booked on is refused outright, confirmed or not, naming the classes: §5's rule that the system never picks who loses their spot is about capacity, and taking their Tuesday away entirely is the same act with a bigger blast radius.

**COUNT was a rolling window pretending to be an ending.** It stopped after N inserts *per run*, counted from today, so every nightly run topped the series back up: a COUNT=4 series produced 4, then 8, then more, forever. `rrule_last_date()` resolves UNTIL and COUNT to one date once, and from then on COUNT is an end date like any other. A rule that ends must not depend on how often the cron happened to run.

**The form is controls, never a text field.** The parser handles FREQ=WEEKLY with BYDAY, INTERVAL, UNTIL and COUNT and raises PT422 on the rest, so the day picker, the interval select and the ends control are exactly what it understands and nothing else — a studio should not be able to type a rule that fails at save. UNTIL is shown as `ends_on` rather than as a second control: the generator already takes the earlier of the two, and a form offering both is one where somebody sets one and wonders why the other won. `update_series()` still raises PT422 either way; the screen is convenience, not the boundary.

**Instructor blank is the normal case and the form has to say so.** Left open, every class the series makes is a Decision 17 open shift that instructors can apply for and that "fill a month" can assign. Unlabelled, an empty select reads as a field somebody forgot.

**The setup checklist could reach "you are set up" and then hand back an empty month.** It now carries the three things filling needs, and NOT at equal weight, because that would be the "6 of 7 forever" mistake in a new place. Qualifications hold the list open — an empty mapping means qualified for nothing (060, deliberately), so an unmapped roster makes the engine return nothing. Availability and commitments are marked optional: `instructor_available_at()` returns true for somebody who has never stated any, on purpose, and with no commitments the run says it is falling back to fewest-classes rather than claiming a target. Each ticks when EVERY active instructor has one, not when any does — one unmapped instructor is a person the engine will silently never use. "Put your week on" also stops pointing at `/classes/new`, which asked people to add fifty-two classes by hand.

**A React toggle that computes from a prop is a toggle that loses clicks.** The day picker built its next array from the captured `days`, so two clicks inside one render both read the same value and the second discarded the first — invisible with a mouse, reproducible the moment anything clicked faster. The updater form is not a style preference here.

****`purge_demo_data` destroyed real data on production, and the function was not what was wrong with it.** It only ever deleted rows where `is_demo` is true. The damage came from a cascade off one of those deletes: `class_occurrences.series_id -> class_series` is **ON DELETE CASCADE**, so `delete from class_series where is_demo` took every occurrence of that series whatever the occurrence's own flag said — and with them, by further cascade, every booking, check-in and timeline event hanging off those classes. Reproduced before fixing anything: 342 demo occurrences and **680 real ones**, the purge reported 342, and the real ones remaining afterwards were **0**. Exactly the shape of migration 058's ON DELETE SET NULL finding — a delete that succeeds while destroying more than it should, and says nothing.

**The generator was the other half.** Since migration 057 a `class_series` insert fires a trigger that materialises twelve months of occurrences, and those came out `is_demo = false` — the demo generator never touched them. So a demo studio filled up with rows the purge could not reach by flag and could only reach by cascade. `generate_demo_data()` now marks what its own trigger caused.

**A purge that cannot prove it took only demo rows must not commit.** Fixing the cascade fixes the path we know about. `purge_demo_data()` now counts every non-demo row for that studio before and after and RAISES if a single one has gone, rolling the whole transaction back — so the next cascade nobody predicted fails loudly instead of quietly. It caught a second one during the build: `timeline_events` and `instructor_availability` have no `is_demo` of their own, so "real" there means "belonging to a real parent", and stating that precisely was forced by the guard rather than remembered.

**A record you have edited is yours, so editing a demo row clears its flag.** Typing a real person's name over a demo instructor left `is_demo` true and the row silently purgeable — the likeliest explanation for the three instructors production lost that no cascade accounts for. Promoting rather than refusing the edit, deliberately: using the demo as a starting point is a real onboarding path, and refusing at save time throws away what somebody just typed and teaches them the demo is a trap.

**What counts as an edit is the whole difficulty.** Machine-maintained columns must not promote anything, or a demo studio becomes unpurgeable the first time the nightly health job runs. The trigger ignores a per-table list of system columns and compares everything else — the same shape as `guard_member_self_update()`, and with the same property: **a column added later counts as human**, which errs toward keeping a row rather than deleting one. `auth.uid()` must be set, and the generator and the assignment engine both exempt themselves with a transaction-local flag.

**`auth.uid()` survives `reset role`.** `set_config(..., false)` is session-scoped, so a test that resets the role and then writes is still writing as the last signed-in user. Two suites promoted a demo fixture by accident before this was noticed; fixture setup clears the claim explicitly now.

**The purge says what it will delete and waits**, the same two-step as `archive_record()`. There is no screen behind it — an operator runs it in a SQL console, which is exactly the situation where nothing makes you stop and read. The first call returns `will_delete` per table and `will_keep` (the census); only `purge_demo_data(studio_id, true)` acts. Adding the confirm argument meant DROPPING the one-argument signature first: a default does not replace a signature, it creates an overload, and every existing call then fails as ambiguous — migration 028's trap.

**A demo row the purge keeps survives with its derived id, so the generator has to step around it.** Demo ids are `md5(studio_id || ':' || kind || ':' || name)` and deliberately deterministic, so a promoted instructor or a plan pinned by a real membership collides on the next generation. The scaffolding inserts take `on conflict (id) do nothing`, and a promoted MEMBER is dropped from the generator's working set entirely — otherwise the demo attaches fake bookings to a real person, which is what collided on `bookings_one_live_per_member`, a partial unique index no `on conflict (id)` could have caught.

**Rebuild a function from the latest migration FILE that defines it, never from the database you have been iterating on.** Twice in one session a copy taken with `pg_get_functiondef` contained an earlier, wrong draft of the very migration being written, because that database had already had it applied — once producing a function that called itself and died on stack depth, once silently reverting a fix made minutes earlier. And migration 017's text was equally wrong for `generate_demo_data`, because 057 already owned it: the right base is the newest file, not the oldest.

**Detaching, not deleting, is the right trade for a real row on a demo parent.** A real class generated against a demo series keeps its bookings and loses its link to the series; a real class taught by a demo instructor becomes a Decision 17 open shift. The series is fiction, the class is not. This also unblocks migration 058's delete guards, which count references and would otherwise refuse to delete a demo instructor a real class still names.

**The calendar's own latency: measured before anything was changed, and the server was never the problem.** Server execution for a whole day's render is **~14 ms in total** — `staff_bootstrap` 4.7, `schedule_range` 5.0, `next_class_day` 2.2, `studio_today` 1.0, the instructors read 0.2, `insight_threshold` 0.5. One HTTPS round trip to the hosted project measures **~58 ms median** from here and several times that from Manila. So every millisecond a studio waits is a round trip, and the only number worth reducing is **how many of them are in sequence**.

**The page had reintroduced the chain the earlier latency work removed.** Four awaits deep: `staff_bootstrap` → `studio_today` → the parallel batch → `next_class_day`. Two of those existed for no reason.

- **`studio_today()` was a whole serial hop to learn a date.** It had to finish before the page could even name the day it was about to ask for. `Intl` carries the same IANA rules Postgres does — checked against hosted, both say `2026-09-10` for Asia/Manila while the server's own date is the 9th — so `studioToday(tz)` computes it for nothing. The SQL function stays for callers already inside the database; nothing holding a timezone should pay a round trip for it.
- **`next_class_day()` was a fourth hop behind an `if`**, firing only when the day was empty — which is precisely the render that was already slowest to say anything useful. It costs 2.2 ms of server work, so it joins the batch unconditionally.

**Two hops now, which is the pattern the rest of the app already follows.**

**Nothing on screen said a fetch was happening, and that is most of what "slow and unreliable" meant.** `router.push` was called bare. The grid is controlled by `anchor`, which comes from the server, so a press moved nothing at all until the round trip landed and then swapped everything at once. Wrapped in `startTransition`, React keeps the **current** grid mounted while the next one loads: the previous day stays on screen, dimmed, under a "Loading…" pill, with `aria-busy` set. Verified by sampling the DOM across a Next press — **the block count never reached zero**. A day with classes can no longer flash as an empty grid, which is the confusion that cost three rounds on this screen.

**"Sometimes entries only appear after a manual refresh" was Next's client Router Cache.** Next 14.2 holds a dynamic route's RSC payload in the browser for **30 seconds**, so navigating back to a day visited moments ago replays the old payload; a hard refresh is the only thing that bypasses it. On a staff console over live data that is the wrong trade — a stale roster is worse than a refetch, and a refetch is one round trip against 14 ms of work. `experimental.staleTimes.dynamic = 0`. Verified: Next then Back within seconds now issues the requests instead of replaying.

**Prefetching was justified by the measurement rather than assumed.** Since the wait is latency and not query time, the adjacent days are `router.prefetch`ed on every render — Back and Next are already in the browser before they are pressed. Confirmed in the network log.

**The calendar was empty a fourth time, and this time nothing was broken.** Reform Collective's `studio_today()` is 10 September; its timetable has **150 classes in November and 46 in December and nothing before**. So the calendar opened on a day that genuinely has no classes and was correct to draw an empty grid — and react-big-calendar's toolbar offers **Today, Back and Next and nothing else**, so the first class was fifty-two presses away. There was no date control anywhere on the screen.

**Every reported detail was consistent with that, including the one that looked like proof of a bug.** The gutter at 06:00–20:00 was read as "still hardcoded"; it is what the derived hours produce **from no rows at all** — the fallback is `07:00`/`20:00`, giving 6 and 21, whose labels run 06:00 to 20:00. It is also, by coincidence, exactly what November's real data derives. **The gutter could not distinguish the two states and I used it as evidence that it could.** Checked properly and it proved nothing either way.

**Reproduced locally by copying hosted's shape rather than by reasoning**: studio in Asia/Manila, today 10 September, 150 classes all in November, six instructors. `/schedule` drew an empty 10 September with a 06:00–20:00 gutter, and `?d=2026-11-02` drew all five of that day's classes at 07:00, 08:00, 09:00, 17:00 and 18:00 Manila in a Prague browser against a UTC server. The screen was right about everything it was asked.

**An empty calendar that cannot point at the timetable it is a view of is indistinguishable from a broken one.** `next_class_day()` answers "where are they, then" in the studio's own days — forward first, backwards if the timetable has ended, and "none at all" as its own sentence — and the empty state links straight there: *"Your next classes are on Sunday 1 November — 5 of them."* A date input sits in the toolbar beside it. Both exist because the absence of them cost four rounds of looking for a fault in code that was working.

**The fixture that reproduced it was itself wrong first, in the exact way this file already warns about.** `generate_series(date, date, interval '1 day')` yields **timestamptz**, so `(d + time) at time zone 'Asia/Manila'` converted the wrong way and the classes landed at 23:00, 00:00, 01:00. The calendar then displayed those instants correctly in Manila time and I nearly read the shifted hours as a rendering bug. `::date` the loop variable. The trap was recorded in CLAUDE.md and cost an hour anyway.

**The calendar was STILL empty on hosted after all three of those were fixed, and the reason was that a migration had been edited in place.** `schedule_range()` in production raised on its own first statement — `42702 column reference "id" is ambiguous` on `select timezone from studios where id = p_studio_id` — because hosted carried the FIRST draft of migration 070, whose `RETURNS TABLE` begins `id uuid, name text`: OUT parameters that shadow the columns the body reads. That was hit locally, the names were changed to `occ_*` **in the migration file**, and `db reset` replayed from scratch and looked fixed. Hosted had already recorded `20260830800000` as applied and never replays it. **An applied migration is immutable — fix forward, never edit in place.** The rule was already in this file; this is what breaking it costs.

**Every symptom followed from the function raising, including the one that looked like a separate bug.** PostgREST returned the error, the page read `data` and ignored `error`, `rows ?? []` came out empty, the grid drew nothing — and with no rows the derived visible hours fell back to their default, which is why the gutter still began at 06:00 and looked hardcoded when it was not.

**A FAILED QUERY MUST NOT LOOK LIKE AN EMPTY WEEK.** That is the fix worth more than the migration. A function that raised on every call for a week was indistinguishable from a studio with nothing on, so the blankness became the bug report while the error message sat unread in the response the whole time. `/schedule` now renders the failure, in words and with the database's own message, and its empty state says which timezone it is empty in.

**`supabase migration list` records THAT a version ran, never WHICH.** It showed all seventy applied and agreed with itself while two functions differed from their files. **Diff the definitions instead** — `scripts/check-hosted-drift.sh` md5s every function in `public` on both sides and prints what differs. It found the second divergence in one pass: `purge_demo_data(uuid)` on hosted with no two-argument signature and no `demo_purge_preview`, meaning migration 062 had been edited in place too, in an earlier session. Migration 062's census guard IS present there — the protection that refuses to commit when a non-demo row has gone is intact — but the confirmation step never reached production, so on hosted that function still deletes without asking until 071 is pushed.

**That script then spent several sessions reporting every function as diverged, which is worse than not having it.** It captured the hosted fetch with `2>/dev/null` and checked neither the exit status nor the result, so a failed read produced an empty list and all 209 local functions were printed as divergent — and a tool whose output is always the same is one nobody reads, including on the day it is right. The reported cause was wrong too: `supabase db query` prints clean JSON on **stdout** and puts "Initialising login role..." on **stderr**, so merging the two streams was what made it unparseable. It now keeps them apart, `die()`s with the database's own error, and **refuses to compare at all if either side came back empty** — "one side has no functions" is a failed read, not a divergence. `--self-test` proves the comparison without touching production: local against a copy of itself must be silent, and one deliberately altered function must be the only thing it names.

**"Missing on hosted" is only innocent while an unpushed migration would explain it.** The script reads `supabase migration list --linked` and says which of the three states it is in — an unpushed migration named, nothing unpushed (**drift**, exit 1), or the list unreadable (**unknown**, said out loud rather than assumed innocent). Both branches were exercised before this was believed. That distinction is what turned the first honest run into migration 076: hosted had applied every migration through 075 and `flex_pending`, `flex_report` and `sweep_flex_decisions` still did not exist there.

**Reasoning from local cannot find a hosted-only fault, and "it works locally" is the evidence that it will not.** The Manila fixture, the three-zone check and 1,275 passing assertions were all true and all irrelevant: local replays the files and hosted replays history, and the whole class of bug lives in the gap. Diagnose against hosted.

**The staff calendar rendered an empty grid for every day, and three separate faults were doing it.** Diagnosed before changing anything, against a fixture reproducing the reported data — a Manila studio with classes on Wednesday 18 November:

1. **The fetch window was fixed and the navigation was not.** The page selected `now() - 7 days` to `now() + 28 days` on the SERVER at render time, while moving between days was client state that never refetched. Measured with the page's exact query: **0 rows returned while 2 existed for that day.** Every date outside that 35-day window drew an empty grid, which is why "every day of November" was empty.
2. **Every instant was rendered in the browser's zone.** A 07:00 Manila class is stored `2026-11-17 23:00+00`; a Prague browser drew it at 00:00 on the **seventeenth** — the previous day, and outside the working hours the grid showed. Right instant, wrong day, invisible either way.
3. **The visible hours were hardcoded 06:00–22:00 of the browser's day.**

**The date and the view are in the URL, so the range and the navigation are the same thing.** `?d=YYYY-MM-DD&view=day|week`; the page fetches exactly the days being shown and moving is a server navigation. Holding them in component state is what made the fetch and the display disagree.

**The day boundary is resolved in the database.** `schedule_range(studio, from, to)` takes a range of the studio's OWN dates, converts before comparing, and returns `local_date`, `local_start` and the minutes already worked out. Doing it in the page means doing it again in the next caller, slightly differently — and Postgres is the only participant that has never been confused about a timezone. `studio_today()` beside it, because `now()::date` on the server is a different day from Manila's for most of the world's hours.

**react-big-calendar has no timezone, so it is handed wall time and converted back on save.** `lib/tz.ts` is the whole of it: `toStudioWall()` makes a Date whose BROWSER-LOCAL fields read as the studio's clock, `fromStudioWall()` is the inverse and runs before anything reaches `move_occurrence()`. Nothing between those two calls is a real instant, which is why they are named `wall`. The alternative — an offset carried through every render and comparison — puts the same lie in fifty places instead of two.

**The visible hours come from what is on the schedule.** Derived from the studio-local minutes the reader already resolved, floored an hour either side. 06:00–22:00 was a guess about somebody else's studio; the local seed switched to Manila has a class at **00:00**, which that window could not draw at all.

**Verified across three zones at once**: server UTC, browser Europe/Prague, studio Asia/Manila. The grid opened on **Manila's** today (the 10th, while the server's was the 9th) with its classes at 00:00 and 15:30 Manila, the gutter starting at midnight because the data said so. 20 October — outside the old window entirely — now renders.

**The instructor columns were not wrong.** `instructors_staff_read` is studio-scoped and the resource query returns exactly the studio's active instructors, checked directly; all resources render. The two lists reported are contiguous alphabetical runs of one list, which is horizontal clipping at seven columns rather than a wrong query — not reproduced here with three instructors, so the fix is defensive: a floor on column width and the view scrolls sideways instead of squeezing names until they read as the wrong people.

**Times are 24-hour on the calendar now**, like every other time in the product. react-big-calendar defaults to the locale's, which put "3:30 PM" beside a roster reading "15:30".

**THE RULE, and it now has a test that can fail: every time displayed anywhere is the STUDIO's timezone.** Never the browser's, never the server's. A fixture where the studio, the server and the browser share a zone tests nothing about this, which is why the suite runs Prague and Manila through `schedule_range()` in one pass and asserts the 23:00-UTC class lands on Manila's 18th and not its 17th.

**`/` is the Dashboard and `/schedule` is the Schedule.** The home screen was labelled "Schedule" and the actual timetable was labelled "Calendar", which had them exactly backwards. Every label, title and link swept: the rail, the home screen's own heading, five "Back to schedule" links, and the applications screen's "Back to the calendar". The day being shown moved from the page title into a section label beside the rows — it was the only place the date appeared in day view, so the title could not simply be renamed.

**The Dashboard does not yet meet its name, and that is recorded rather than implied.** Bible Ch. 4 lays the screen out as ten blocks — AI Daily Brief, KPI cards, revenue chart, attendance chart, today's classes, AI insights, member health, recent activity, upcoming tasks and a calendar — against the five questions an owner should be able to answer in thirty seconds. **We have two of them**: the Morning Brief (which carries the insights) and today's classes, plus a money banner. No KPI cards, no charts, no member-health block, no recent activity, no tasks. Calling it Dashboard is right — it is the brief and what needs attention — but the name is currently a promise.

**The calendar shows fullness, and the number is the biggest thing on the block.** `booked/capacity` in tabular mono, right-aligned so a column of them lines up, which is the whole reason to read one. Waitlist beside it when there is one. A ring for full, a plain surface and a grey rule for quiet, amber for unstaffed, coral and hatching for unstaffed-with-members-booked-and-close. **Staffing outranks fullness** — nobody teaching it is a bigger problem than nobody in it, and two loud states on one block is neither.

**"Quiet" is §11's definition, not a second one.** The Morning Brief already decides what underfilled means — below `underfilled_pct` of capacity within `underfilled_window_days`, with `overfilled_pct` for the other end — so the calendar reads those same `insight_config` rows through `insight_threshold()`. A second threshold on this screen would have agreed with the brief exactly once. Quiet also only shows inside the window: a class three days out at two of eight is a decision, the same class in five weeks is just early.

**No second fetch.** `booked_count` and `waitlist_count` are columns on `class_occurrences`, which the calendar was already selecting; the change is one more column in an existing select. The per-instructor column headers are derived from the events already in hand, so a column reads as one person's day — "2 classes · 7/16", or "Free all day" — rather than as an anonymous grid.

**Clicking a block opens the roster that already exists.** `/roster/[occurrenceId]` knows about photos, pinned notes and check-in state; the calendar links to it rather than growing a second one.

**`booked_count` was checked before being trusted, and the first check was wrong.** Counting "currently booked" reported **312 of 891 occurrences drifting**. The rule `book_class()` and `cancel_booking()` actually implement is +1 on book, −1 on cancel — so `attended` and `no_show` KEEP their seat, and a seat is taken by anything that is not cancelled, late-cancelled or waitlisted. Under the real rule: **Reform Collective, 455 occurrences, 0 booked drift, 0 waitlist drift.** The cache is trustworthy. The eight disagreements on the whole database are all in test-suite studios whose fixtures insert bookings directly.

**There was no nightly reconcile behind it — that had been assumed.** Grepping every function in the schema for `booked_count` returns the two writers and nothing that recounts. Any other writer of `bookings` drifts silently and forever. That was tolerable while the number lived in a metadata line; it is not now that it is the largest thing on every calendar block. Migration 069 adds `reconcile_booked_counts()` on pg_cron at 03:40 — after the generator at 03:10 — writing only the rows that are actually wrong, because rewriting all of them would touch `updated_at` on every occurrence every night and lie about when the class last changed.

**The occurrence horizon was a setting no screen had ever read or written**, which is the third instance of this exact shape after `instructor_availability` and `class_series`. Its default of twelve months is why Reform Collective was carrying **1,421 open classes through September 2027 that nobody had agreed to teach and any member could book**. It is now days rather than months, defaults to **60**, and lives at `/settings`.

**Days, not months, and not because of unit tidiness.** "Two months" from the 31st is a question with three answers, and a horizon is a rolling window rather than a calendar boundary. Sixty days is this month and the next — how a boutique studio plans, and the month migration 066's availability cycle collects for.

**Shortening it used to do NOTHING, and that had to be proved rather than assumed.** Set to two months, ran the nightly job: furthest class still 2027-09-09, 680 still scheduled. `generate_occurrences()` only ever inserts, so the setting could only grow the calendar. `set_occurrence_horizon()` now sets and trims in ONE action, deliberately — a setting that shortens and leaves 1,421 classes standing is the bug, and splitting the two would recreate it with an extra button.

**Deleted, not cancelled — and the reason is the slot index, not the room.** A cancelled row keeps its `series_slot_at`, and the unique index on `(series_id, series_slot_at)` is what makes regeneration idempotent; so a studio that shortened the horizon and later lengthened it again would find the generator skipping every cancelled slot and the calendar permanently holed. Proved: cancel one slot, restore the horizon, regenerate — `created: 0`, slot still held. (A cancelled class does *not* hold its room, incidentally: both exclusion constraints are partial on `status <> 'cancelled'`.)

**A horizon may only delete what the generator itself made and nobody has since touched.** A booking or a check-in refuses the whole change, confirmed or not, naming the classes. A class somebody has moved (`is_exception`), one a human assigned an instructor to (`assigned_by`), and a **one-off with no series at all** are kept and reported — creating a class eight months out is a deliberate act, and a horizon that swept those away would be deleting what somebody typed.

**Counted from the bookings, never from `booked_count`.** The refusal detects through the `bookings` table and first *reported* the cached column, so a class it was refusing to delete read "0 booked". Found by driving the screen. The cache is maintained by `book_class()` and an import or a hand-written row leaves it behind.

**A preview and an apply that read the number from two different places will eventually disagree.** The apply form posted React state while the preview form posted the DOM input; driving the screen produced a preview of 60 days and an apply of 365. The apply now carries back the number the PREVIEW computed, so the two cannot differ — the same rule the fill screen already follows by re-running rather than replaying.

**An instructor submits their own month; staff approve it; only an approved pattern reaches the engine.** Same Calendly-style editor Decision 18 gave the studio, on the instructor's side, at `/my/availability`. Draft, submitted, approved, changes requested — and a review that sends it back must carry a reason, because "changes requested" with no note is a refusal wearing a softer word.

**Everything that already existed was already approved, and the DEFAULT is what guarantees it.** `instructor_availability.approval_status` defaults to `'approved'`, so the ALTER rewrote nothing and Reform Collective's instructors kept working through the migration — checked: 31 rows, all approved, all still evaluating true. A manager calling `submit_availability()` also lands approved, for the same reason: staff entry IS the approval, and making a manager review their own typing is a queue nobody asked for.

**A submitted month WINS FOR ITS OWN DAYS rather than replacing or merging with the standing pattern.** The alternative was truncating and splitting: a Jul–Oct pattern with a submitted September has to become two rows, and a studio that later deletes the submission does not get its pattern back. So `instructor_available_at()` gained one precedence level — dated exception, then approved submission covering that day, then the standing pattern, then "nothing stated means available" — which is the same shape the exception rule already had. Nothing is destroyed to make it work.

**A pattern waiting for approval must narrow NOTHING.** Including the "has this person stated anything at all" test, which is the subtle half: an unapproved submission would otherwise flip somebody from "stated nothing, so available" to "stated something, and this class is outside it" before anyone said yes. Proved by reverting the filter — the suite fails on exactly that assertion.

**The monthly cycle is a column, never a constant.** `studio_settings.availability_due_day`, default 20, capped at 28 so the date exists in February. The due date, the daily reminder and the "who hasn't submitted" list all read that one column, and the suite asserts two studios computing different due dates from the same code. The reminder test asserts the *invariant* rather than a day: whatever `availability_cycle()` publishes as `overdue`, the queue agrees with it — which is what makes the setting real and holds whatever date the suite runs on.

**One press for the week, with the list visible.** `/my/week`: "Confirm all 11 classes" over the classes themselves, and per-class "ask for cover" beside each, which raises Decision 18's flow. A class somebody has asked cover for is ANSWERED, not unconfirmed — chasing them about a class they have already said they cannot teach is the opposite of what this is for. `confirm_week()` skips those and reports the count separately.

**The timing is the feature, and all of it is per studio.** Ask on Thursday for the week ahead; remind ONCE on Saturday if nothing has been answered; escalate on Sunday and only for classes inside the next three days — `week_confirm_ask_dow`, `_remind_dow`, `_escalate_dow`, `_escalate_days`. A Friday class unconfirmed on Sunday is not yet a problem, and reporting it as one is how a studio learns to ignore the alarm. The suite runs two studios on different settings through ONE sweep: today is studio A's ask day and tomorrow is studio B's, and only A is asked.

**An unconfirmed class is NOT an open shift.** Nothing in 067 touches `staffing` or `instructor_id`. Auto-opening a class because somebody was on holiday and missed a button is a worse failure than the one it solves — the class had an instructor and now it does not, and nobody decided that. The suite asserts it directly, and the staff screen says it in words.

**Staff get one line.** "2 instructors have not confirmed 5 classes this week", with who and which classes, composed in `unconfirmed_summary()` rather than in a screen — so the escalation email, the page and anything later cannot each phrase it slightly differently. The escalation is ONE email to the studio, deduped per studio per day, never one per class. Confirming late clears the whole thing silently: the summary is derived from the classes, so there is no "you were late" state to dismiss.

**`instructors.staff_id` is a `studio_staff` id, not an auth user id.** Both new migrations were written passing it straight to `queue_shift_notice()`, which takes the latter — caught by a foreign key in the test fixtures rather than by reading. `instructor_user_id()` is the join, and it returns null for an instructor with no login, which is the ordinary case: two of three seeded instructors have none, so the screens say "no login, so no reminder can reach them" instead of implying an email that was never sent.

**`week_starts_on` has been a setting since migration 001 and `date_trunc('week')` always means Monday.** `studio_week_start()` exists so a studio whose week starts on Sunday is asked about the right seven days; the suite moves a studio's week to start today and asserts it.

**Not built, and recorded rather than implied:** neither feature adds a Morning Brief insight. The brief's `generate_morning_brief()` would need replacing again, and both surfaces already have somewhere to live — the escalation is an email plus `/availability`, and the submissions list is that same screen. Adding `week_unconfirmed` and `availability_missing` to the brief is a later, separate change.

**The commitment measures instructors; it does not schedule them.** `instructor_commitments` is a hiring expectation — 9–12 classes a week over an agreed three-month term — and a performance measure. It is not a scheduling input and must not reach booking, assignment eligibility, the availability window or anything a member sees. Migration 061 got this wrong in two places and 065 removes both.

**"Furthest below their target" is a true number with a false meaning.** The engine ranked candidates by deficit against `target_per_week`. A studio running 35 classes a week across six instructors cannot give anybody twelve, so that phrase would have appeared on **every line of every run summary**, describing a gap the studio has no way to close and the engine no business trying to. Distribution is now by **fewest classes assigned that week, full stop** — which is exactly what the no-commitment fallback already did, so the fix deleted a branch rather than adding one. `commitment_fallback`, `no_commitment_for` and the per-line `deficit` go with it: with no other behaviour to fall back *from* there is nothing to report, and the fill screen's banner offering "set their commitment and the next run will aim at it" was promising something that must not happen. Proved by putting the ranking back: one instructor on a target of 12 took all six classes instead of three.

**A default can be a hard gate wearing a soft word.** 061 filled a blank availability `effective_from` / `effective_to` from the live commitment so the pattern and the agreement "cannot drift apart". But the validity window is a hard gate — the engine, the cover board and `move_occurrence()` all refuse outside it — so an agreement reaching its end date silently made somebody unschedulable. The commitment was deciding the roster by a back door, through a line of code whose stated purpose was tidiness. Blank now means open-ended. `cover_and_commitment_test.sql` asserted the old behaviour and now asserts its inverse.

**What the commitment IS for is `commitment_report()`.** Per instructor over the agreement's own period: classes per week against the agreed minimum, weeks under and weeks at or over, the average, the trend of the recent weeks against the earlier ones, and a standing. It counts through `instructor_weekly_load()` — the same function `commitment_shortfall` uses — so the brief and the report cannot disagree about what a week contained. **Complete weeks only:** the current week is a number still going up, and putting it in a performance measure makes everybody look short every Monday. **Standing is measured against the MINIMUM, never the target**, for the same reason the target is not a ranking input.

**The report caught two of my own wrong expectations while its test was being written**, which is the argument for building it: on real seed data Reform Collective's three instructors are all under, because a 13-class week across three people cannot reach minimums of 6 to 9. That is a true and useful thing for a studio to see, and precisely the number the engine must not act on.

**`commitment_shortfall` stays in the Morning Brief, unchanged.** An instructor persistently under what they agreed to is a conversation worth surfacing in week three rather than month three. It is a management signal, never a scheduling input.

**Availability has two levels and only one of them is a warning.** The VALIDITY WINDOW (`instructor_availability.effective_from` / `effective_to`) is a hard gate everywhere — the engine, the cover board's candidate list and `move_occurrence()`, which now refuses with `outside_availability_dates`. Somebody whose pattern runs only through November has not agreed to be anywhere in December, and offering them invites a human to pick a person who never said yes. Decision 9's "warns, never blocks" is about overriding somebody's stated HOURS, which a human can do knowing why; it was never about putting them outside the dates they agreed to at all. The day and time INSIDE the window stays a warning for a human and blocks for the engine — a person assigning outside stated hours knows what they are doing, an engine doing it produces a class nobody turns up to teach.

**An empty qualification mapping means NOTHING, not everything.** The expensive reading, on purpose: "no rows means anyone can teach anything" makes the feature invisible until it is wrong, and every studio is unmapped on the day it ships. So every screen that shows it says so — an unmapped instructor gets an amber line reading "not down to teach anything yet", not a blank list.

**`assigned_by` marks a human choosing a PERSON, never a human clearing one.** The first version marked any instructor change, which meant that after archiving somebody, "fill November" silently skipped every class they had been on — a vacancy is exactly what the engine exists to fill. Found by the suite: six reopened classes came back marked and the engine filled one of them. The one deliberate clearing is "publish this as an open shift", which `approve_cover_request()` stamps itself, because staff asking instructors to apply is a decision the engine must not undo. Checked by removing the gate (the engine overwrites a manual choice) and the trigger (the mark never appears).

**There is no commitment fallback any more, and its absence is the point.** The engine used to compute `deficit = coalesce(target_per_week, 0) - classes_this_week`, degrade to "fewest classes that week" when no commitment was on file, and report that degradation as `commitment_fallback`. Migration 065 makes fewest-classes the only rule, so there is no second behaviour to fall back from and nothing to announce. Every assigned line reads "3 classes that week, fewest of the candidates".

**`pg_get_functiondef` is only trustworthy if you know what has been applied.** Fixing 053's writer forward, the copy taken from the live database was itself the wrapper — because that database had already had an earlier, wrong version of 061 applied to it. It called itself and the next test run died on stack depth. Take the original from the migration FILE, not from a database you have been iterating against.

**The timeline had no writer, and the screen said so wrongly.** `rebuild_member_timeline()` has existed since migration 021 and the ONLY references in the whole repo were `supabase/seed.sql`, once at the end, and migration 033. There is no trigger on `check_ins`, so a member with 46 visits read "Nothing recorded yet" — and would have gone on reading it forever, because the seed made local look fine and production had never run it at all. Migration 059 moves the derivation into an unguarded internal, keeps the manager-up guard on the public entry point, and triggers a **rebuild** (not an append) from `check_ins`, `bookings`, `payments` and `memberships`. A rebuild because it is idempotent by construction and cannot disagree with itself; an append-only trigger would be a second copy of eleven queries and the first one edited would silently diverge — the rule migration 021's own comment set out.

**Two existing suites asserted "no timeline events" and both were wrong once it had a writer.** The importer and health suites grouped it with "no notifications, no challenge progress, no achievements" — things that *reach a person*, which importing history must not do. A timeline event reaches nobody; it IS the history, and migration 021 derives `attended` from imported check-ins deliberately, with its own "Imported from your previous system" description. Both now assert that imported attendance *does* land on the journey. They read 0 only because nothing wrote it.

**A `FOR ALL` policy grants SELECT, and permissive policies are OR'd.** `documents_desk_write` as `for all using (is_desk_up(...))` silently handed front desk read access to the medical documents the narrower SELECT policy existed to withhold — the test caught it at 2 documents where 1 was right. INSERT, UPDATE and DELETE are spelled out separately now, and UPDATE carries the same medical narrowing, or front desk could edit a row they cannot read.

**Pinned notes did not surface on the roster, which is the only reason pinning exists.** `app/staff/roster/[occurrenceId]` never queried `member_notes` at all, so "Pin to the roster" was a checkbox that set a boolean nothing read — and the seed's own pinned injury notes had been invisible in every environment. The roster now reads them in one query for the whole list and shows injury and medical in coral above the row.

**Staff could not upload a member's photo.** `member-avatars` has been readable by staff since 035 and writable only by its owner, so the walk-in signing up at the desk — exactly the person who will not do it themselves — could never have one. `avatar_url` was also never rendered on the staff member screen.

**Filing a signed waiver is what sets `members.waiver_signed_at`.** That timestamp has gated §2.1 booking since migration 002 with no document behind it, so "signed" meant "somebody ticked it". `record_document()` sets it on the first waiver and leaves an already-signed one alone. Medical documents are manager-up and instructors see none at all — §14 denies them contact details and this is the same rule; front desk take waivers at the counter and have no reason to read a diagnosis.

**`member_goals.current_value` was a cache nothing ever wrote**, so every goal read "0 of 12" however often the member came. Counted live from `check_ins` instead, and **from the day the goal was set** — twelve classes agreed in March is not already met by last year.

**`status` was on three tables and no member-facing policy had ever looked at it.** Asked as a real member session before writing anything: an archived instructor, class type and room were all fully readable, bio included. The `/book` filter pills happened to filter in the query and the class detail screen joined through the occurrence and did not, so archiving hid a class type from one screen and left it on another. The fix is in the POLICY, not the screens — there are eight places the member app reads these three tables and a rule living in eight queries is one the ninth will not have. Each hidden row degrades into a path the app already handles: a null instructor join is Decision 17's "no instructor yet", a null class type is the no-description case, a null room omits the room line. **The cost, stated:** a member looking at a class taught by a since-archived instructor sees no instructor name.

**Delete already "worked", and that was the problem.** Every FK onto `class_types`, `rooms` and `instructors` is `ON DELETE SET NULL`, so deleting an instructor did not fail — it succeeded and stripped them from every past class. Proved: deleting Bo Fictitious returned `DELETE 1` and took his name off **394 occurrences**. The guards are triggers in the shape of `guard_plan_delete`, refusing with the count and naming archiving as the alternative.

**Archiving an instructor opens her classes rather than refusing.** The choice was refuse or open, and refusing means a studio cannot archive somebody who has already left — exactly when they need to. Future classes become Decision 17 open shifts, which the calendar hatches, the brief escalates and other instructors can apply for; her past classes keep her name, which is the entire point of archiving. **A room is the opposite: blocked, not warned.** There is no "open room" state — nulling `room_id` frees the slot for a double-booking the exclusion constraint can no longer catch, and which room a class should move to is the studio's decision. Archiving a class type stops its recurring series, because a series that goes on materialising an archived type every night is the archive not having happened.

**The three edit forms already had an "Archived" option that skipped all of it.** A plain `<select>` writing `status` directly: no preview, no counts, no opening of the classes, no email, no room block. A manager archiving an instructor from the form would have left her silently teaching next Tuesday — the exact outcome the work exists to prevent. Removing the option is not enough, because the same UPDATE goes straight through PostgREST, so `guard_archive_path()` refuses any transition to `'archived'` that did not come through `archive_record()` (which sets a transaction-local flag). Restoring stays an ordinary update: it has no consequences to skip. `status` was also unconstrained text, so `'Archived'` and `'inactive'` both stored happily and behaved like neither state; it is now a CHECK.

**Occurrences stopped being generated the moment the demo generator finished.** Data model §5 asks for "a nightly job [that] materialises occurrences for a rolling 12-month horizon per series, plus immediately on series create/edit". It was specified and never built: the demo generator materialised 26 weeks back and 4 weeks forward ONCE, and nothing had generated an occurrence since. Hosted was down to **403 occurrences ending 4 October** with today at 9 September — five weeks of timetable left, no error anywhere, and the failure mode is a calendar that quietly empties and members who cannot book. Migration 057 builds it; the backfill took hosted to 1036, twelve months out.

**§5's exception rule protected nothing, because nothing set the flag.** `is_exception` has been on `class_occurrences` since migration 001 and **no code has ever written it** — `move_occurrence()` drags a class and leaves it false. So "leaves it untouched by regeneration" was true only in the sense that there was no regeneration.

**And the flag alone would not have been enough.** A class moved from Tuesday 07:00 to Wednesday 18:00 leaves NO ROW at Tuesday 07:00, so a generator keyed on `(series_id, starts_at)` — the index §5 names — sees a free slot and fills it, and the member now has two classes where the studio made one. `series_slot_at` records which recurrence a row materialises and is **preserved across a move**, so the moved row goes on holding its origin. Proved by removing just that index: `created: 1`, the refill happens. A move now also sets `is_exception`, which is the other half §5 assumed.

**`generate_series` over dates yields `timestamptz`, not `timestamp`.** A test fixture built its blockers as `(d + time '09:00') at time zone tz` and they landed at 13:00 Prague instead of 09:00 — because `d` was already an instant, so `at time zone` converted the other way. The clash test then had nothing to clash with and passed. `d::date` first. The production path is safe because its loop variable is declared `date`, which is what the DST assertion proves.

**A trigger that materialises makes the series form the place a bad rule is caught.** `FREQ=MONTHLY` raises PT422 inside the trigger, so the `UPDATE` that would have saved it fails and the series keeps the rule it had. Better there than at 03:10 the next morning. The parser handles `FREQ=WEEKLY` with `BYDAY`, `INTERVAL`, `UNTIL` and `COUNT` and raises on everything else — a parser that shrugs at what it does not understand is how a monthly series silently generates weekly.

**Two more things collided with the new trigger, both the same shape.** `supabase/seed.sql` and `generate_demo_data()` each insert `class_series` and then insert their own occurrences; the trigger now materialises the forward half in between, so the second statement duplicates. Both take `on conflict (series_id, starts_at) where series_id is not null do nothing` — **named**, because a bare `ON CONFLICT DO NOTHING` tries every constraint as an arbiter including the DEFERRABLE instructor exclusion, and Postgres refuses that outright. What is left in the seed is the history, which the generator will not create and the AI features need.

**A `SECURITY DEFINER` read steps over the policy that was doing its job.** The advisor query in this file asks whether a function is reachable by `anon` and `authenticated`. That is only half the question — the other half is whether anything INSIDE it is standing in the way, and for three availability readers the answer was nothing at all. Proved signed in as an ordinary Reform Collective **member** — not staff, not an instructor, no relationship to the other studio: `select * from instructor_availability where instructor_id = <other tenant>` returned **0 rows**, and `instructor_availability_week(<same id>)` returned their entire weekly pattern. The direct read returning 0 is what makes the diagnosis certain — RLS was working and the wrapper walked around it. `instructor_weekly_load` leaked class counts the same way, and 047's `instructor_available_at` has leaked a boolean since the day it was written. Migration 056 guards all three with the rule the write path already used. **Every SECURITY DEFINER function that takes an id and returns tenant data needs its own check; the grant is not one.**

**Availability was a schema with no editor for fifty-two migrations.** `instructor_availability` has carried `day_of_week`, times, `effective_from`, `effective_to` and `exception_date` since migration 001, and `instructor_available_at()` has read all of them since 047 — against an empty table, in every environment, so every scheduling warning it produced was correct by accident. Decision 18 builds the editor. The week is **replaced as one payload**, never row by row: a half-applied week is reachable otherwise, and a half-applied week silently changes who the scheduler says can teach. Copy-a-day-to-other-days is a client-side operation on the form for the same reason, and it is the control that makes the feature usable — 9-12 consecutive classes a week means most weekdays are the same two ranges, and entering them seven times by hand is how a studio decides not to bother. The seed now carries a pattern and a commitment for every instructor, because an empty table here is indistinguishable from a broken query.

**A cover request changes nothing about who is teaching, and the schema is not what stops it.** `occ_staffing_matches_instructor` forbids `staffing = 'open'` beside a non-null `instructor_id`, and the constraint NEVER FIRES: `tg_derive_staffing()` runs first and silently rewrites `staffing` to agree with `instructor_id`. So `update class_occurrences set staffing = 'open'` on an assigned class succeeds and leaves the row `assigned`. The state is genuinely unreachable and the mechanism is coercion, not refusal — worth knowing before reading the constraint and concluding a stray write would raise. It would not. It would be corrected, quietly.

**Decision 18 overturns one edge of Decision 17.** `withdraw_from_shift()` was unconditional self-release: it cleared `instructor_id` and set `staffing = 'open'` with nobody's approval, which is exactly what "staff always approve, no self-release, however urgent" forbids. It now raises a cover request instead. `scheduling_test.sql` asserted the old behaviour and now asserts its inverse. Withdrawing a *pending application* is untouched — nobody is counting on you before you have been approved.

**An instructor with no login has no address anywhere in the schema.** `instructors` carries no email of its own, so `queue_instructor_assigned()` returns null for anyone with `staff_id` null — which is the ordinary case, not an edge: two of the three seeded instructors have no login, and CLAUDE.md already records that an instructor is a teaching record with no invite. `approve_cover_request()` therefore returns `cover_notified` and `cover_name`, and the screen says "they have no login, so nothing was emailed — tell them yourself" rather than a success message implying an email that was never sent.

**The suites share one `db reset`, so a global `count(*)` is a count of whatever ran first.** `scheduling_test.sql` counted notifications with no studio filter and was correct only for as long as no other suite wrote the same template key; the cover suite does, and it went from 4 to 6 without anything in scheduling changing. Scope every cross-table count to the suite's own studio, the same way its fixtures are scoped to its own UUID space.

**A test that asserts its own ORDER BY asserts nothing.** The first version of the ranking test ordered by a `CASE` written inside the test, so it put `cover_unanswered` first whatever the function did — and passed with the rank set to 2. Rank is only observable through `limit v_max`, so the test squeezes `max_insights` to 1 and asks what survives.

**A banner nobody can act on is the insight-without-a-button mistake again.** The cover banner was showing to instructors, who can read `cover_requests` under `cover_requests_staff_read` and are refused by `/shifts/cover`. `studioBanner()` now takes the role and skips both the banner and the query for anyone below manager.

**A function cannot cross the server/client boundary, and TypeScript will not tell you.** The availability page passed a date formatter into a client component: types clean, `tsc` clean, and an Unhandled Runtime Error the moment the page was opened. Format on the server and pass strings.

**Push does not exist and Decision 18 does not pretend otherwise.** `push_subscriptions` has existed since migration 001 with nothing writing it; there is no service worker subscription, no VAPID keys and no transport. Escalation is email plus two in-app surfaces. **Gap:** same-day cover on a phone that is not open wants push, and push needs a subscription write path, a service worker and a second `send_via_*`.

**Everything through 063 is applied on hosted, and only 064 is not**, confirmed with `supabase migration list --linked` at the time 064 was written: every entry up to and including `20260830730000` shows `local == remote`, none orphaned, and `20260830740000` is the single local-only one. This paragraph said 056 for several sessions after 057–063 had gone up, which is the stale-warning trap recorded below in its other direction — a note that understates what is live is skimmed past exactly as fast as one that overstates it. Practically: the `purge_demo_data` fix and the demo-promotion trigger ARE in production; `update_series()`, the COUNT fix and the three new checklist items are NOT, so editing a series on hosted still doubles the timetable until 064 is pushed. **The advisor query has not been run against hosted for 064**, because 064 is not there; it is owed the moment it is. The advisor query has been run against hosted for the Decision 18 migrations, which is what the rule above asks for after anything that creates a function:

- **anon** reaches exactly the seven pre-login surfaces and nothing else.
- **`notification_api_key`, `send_via_resend`, `render_notification`, `queue_notification`, `deliver_notification` and `send_due_notifications` are all `false / false`** — reachable by neither `anon` nor `authenticated`. Migration 033 did close the Resend key on hosted, and this file claimed otherwise for several sessions after it stopped being true.
- The Decision 18 surface on hosted matches local exactly: ten guarded functions callable by `authenticated`, `queue_instructor_assigned` and `sweep_cover_escalations` callable by neither.

**A stale warning is worse than no warning.** This paragraph said the Resend key was still exposed in production long after it had been closed, which is the kind of note that gets skimmed past once it is known to be wrong — and the next real one with it. When a migration is pushed, correct the record in the same breath.

**Next:** selling a plan to a member (§9 gives front desk that, unlike editing), then cancellation and the waitlist promotion flow.

---

## Rules that are not negotiable

**RLS decides which rows, never which columns.** `members_self_update` is `using (user_id = auth.uid())` and `authenticated` holds UPDATE on all 28 columns of `members`, so "a member may edit their own row" meant a member could set `status`, `waiver_signed_at`, `health_band`, `lifetime_visits` and `studio_id`. Proved: the seeded member with no waiver signed her own and booked the class the gate had just refused.

Column grants cannot fix it — front desk, managers and members are all `authenticated`, so narrowing the grant takes the same columns from the staff who are meant to edit them. The rule lives in a trigger (migration 035) that compares `to_jsonb(new) - owned` against `to_jsonb(old) - owned`, so **a column added later is protected the day it is created** rather than the day somebody remembers it. Any table with a self-service write path needs the same shape.

**RLS is the security boundary.** A permission that exists only in React is not a permission. Every rule in the permissions doc is a policy. Instructor access to revenue is denied at the policy level, not by hiding menu items.

**Every table gets RLS and a grant.** RLS decides which rows; grants decide whether the role may touch the table at all. Both, or the table is either closed to everyone or open to everyone. See migration 001 §16 — but read migration 005 with it: §16 claims there is no pre-login surface, and since migration 004 there is exactly one, `studio_by_slug()`.

**Functions are closed by default, because PostgreSQL's default is the opposite.** A new function is executable the moment it is created. Withholding a grant does nothing; you have to revoke. Say who may execute, every time.

**Revoking from `PUBLIC` is not the same as revoking from `anon`, and only hosted can tell you.** The hosted platform ships default privileges naming `anon` explicitly, so every function created by `postgres` in `public` is born with an `anon=X` grant. The local stack does not do this. Migration 006 revoked from `PUBLIC`, passed every local check, and left eight functions anon-callable in production for five migrations; 011 revoked from `anon` and flipped the hosted default so the next one is not born open.

The lesson is not about one grant. **`supabase db reset` cannot verify grants** — local and hosted have different default ACLs, so the tests agree with the wrong answer. After any migration that creates a function or touches privileges, run the advisor query against the hosted project, not just locally:

```bash
supabase db query --linked "select p.proname, has_function_privilege('anon',p.oid,'execute') as anon, has_function_privilege('authenticated',p.oid,'execute') as authed from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')) order by 1;"
```

**Ask about `authenticated` too, not only `anon`.** Migration 033 exists because this query used to ask about `anon` alone: `anon` is the role we remember to fear, and `authenticated` is every member of every studio, including a walk-in who signed up thirty seconds ago. A function with no guard inside it is as exposed to one as to the other.

The only names of ours that belong in that output are the seven pre-login surfaces: `studio_by_slug(text)`, `studio_invite_preview(text)`, `accept_studio_invite(text,text,text)`, `member_invite_preview(text)`, `claim_member_account(text,text)`, `stripe_webhook(text,text)` and `stripe_platform_webhook(text,text)`. The last is the only one that WRITES, and the only one with no session behind it — see the rule below. As of migration 014 that query returns exactly those seven on hosted, with no filtering needed — re-verified against hosted at migration 056. ("Three" for several revisions, written when there were three and never updated as four more were added; the list beside it was right and the count was not.)

Note what migration 013 found: the query has to enumerate what is *actually there* on hosted, not what this repo creates. `rls_auto_enable()` is installed by the platform, exists on no local stack, and sat anon-callable through migration 011 because 011 only checked its own list.

**Platform billing is not Connect and shares nothing with it.** Connect is the studio's members paying the studio on the studio's account; `platform_subscriptions` is the studio paying us on ours. Two endpoints, two signing secrets, and each refuses the other's events — the platform one rejects anything carrying an `account`, the Connect one anything without. Applying a member's class payment to our own subscription table is the failure this prevents.

**There is no manual fallback for platform billing, and the screen says so.** A studio may take cash from its own members forever under Decision 16; it still pays us by card. We are not chasing bank transfers from ten studios, and a dunning process for our own invoices is not the product. Said plainly in `app/staff/billing` rather than left to be discovered.

**Lockout is a status, never a deletion.** Every read stays open — rosters, members, history, the schedule — so a locked studio never looks like lost data, and paying flips one column back. `cancel_booking()` is deliberately ungated: a studio that cannot cancel a class leaves members at a locked door on a Tuesday, and those members did nothing wrong. Cancelling matters *more* when a studio is in trouble.

**A member of a locked studio is told nothing about why.** `/unavailable` says the studio is not taking bookings and that their history is intact. Not that a subscription lapsed, not what it costs — their studio's business with us is not theirs, and "your studio didn't pay" tells a member something about their instructor's finances they were never entitled to.

**The lockout gate is in `staffScreen()` and `memberScreen()`, not middleware.** Middleware would have to resolve the signed-in user's studio on every request to know which subscription to check; these two helpers are what every screen already goes through with the studio id in hand. They are the real chokepoint. The database gates in migration 045 are the actual boundary either way — a permission that exists only in the app is not one.

**Warnings count down rather than repeat.** Banner from day one of grace showing days remaining, and email on days 1, 7, 12 and 14, deduped per studio per grace period per day. The day is computed by ROUNDING the remaining interval: `extract(day from ...)` truncates 13.4 days to 13, and day one would never have fired at all.

**Studiior is a booking platform, not a payment processor — Decision 16.** A studio records payments however it already takes money: cash, bank transfer, GCash, a terminal on the counter. An online provider is an optional adapter on top. Stripe does not serve the Philippines at all, and a Stripe-shaped product would have excluded design partners whose only problem is booking.

**One path, not two that match.** What makes a manual payment activate a membership *identically* to a Stripe one is that both call `activate_purchase()` and `confirm_dropin_payment()` — the only code that grants anything. Two implementations would agree the day they were written and drift after. The test proves it by diffing the two membership rows field for field.

**The tradeoff is recorded, not policed.** A manual payment is the studio's own bookkeeping: they reconcile it, and a membership can be marked paid when no money moved. Nothing tries to stop that. What the row owes them is who recorded it, when, by what method and against what reference — enough to reconcile, not enough to police. A booking platform that audits its customers' cash handling has misunderstood what it is for.

**Front desk takes money; only a manager gives it back.** Permissions §9 reads front desk "Payments" as *taking* payment. `record_manual_payment()` is `is_desk_up()`, `record_refund()` is `is_manager_up()` — money leaving the studio needs a second pair of hands.

**A full refund takes back what is left, never what was used.** Refunding a pack removes the unused credits and cancels the membership; it does not claw back classes already attended, because you cannot un-attend a Tuesday. A partial refund does not touch credits at all — what a half-refunded pack is worth is the studio's judgement, not a function's guess.

**An optional checklist item does not hold the list open.** `connect_stripe` is optional under Decision 16, so it is excluded from the count in `lib/setup.ts` as well as marked in the UI. A studio taking cash in Manila has finished setting up, and a checklist stuck at "6 of 7" forever teaches people to stop reading it.

**A webhook has no session, so the signature is the credential.** Every other write in this codebase goes through RLS with a real user behind it. Stripe has no user and RLS cannot express "Stripe said so", so the choice was a service-role key that can do anything to any tenant, or a function that will not act without a valid signature. `stripe_webhook()` recomputes the HMAC-SHA256 over the raw body in Postgres before it reads a single field — the same shape as `resolve_checkin_code()`, where the cryptography is the gate rather than the caller's identity. There is still no service-role client in this codebase.

The body must reach it as TEXT and unchanged: the HMAC is over the exact bytes Stripe sent, and a `JSON.parse` followed by a `JSON.stringify` reorders keys and invalidates it.

**The tenant comes from the `account` field, never from metadata.** Stripe puts the connected account id at the top level of a Connect event; we put metadata inside the object. An event whose metadata names a different studio than the account resolved to is refused outright, and an event for an account we do not know is recorded and NOT processed rather than guessed at.

**Idempotency is the insert, not a check.** `stripe_events` has Stripe's own event id as its primary key, so a replay conflicts, inserts nothing and returns before reaching a handler. Stripe retries on any non-2xx for days, so this is a certainty rather than a precaution — which is also why `duplicate` and `unknown_account` both answer 200: neither is something Stripe can fix by sending it again.

**A held seat is not a booking.** A drop-in at a Stripe-connected studio is created as `pending_payment`, not `booked`. It holds its seat — taking someone's place while they type a card number is worse than briefly overstating how full a class is — but it does not count toward the daily or forward limits, it sends no confirmation, and it reads as "holding your spot" with a way back to Checkout. Three abandoned checkouts must not use up three of today's classes.

It is a status and not a flag on purpose: thirty-four places filter on booking status, and with a flag every one of them would go on treating an unpaid booking as confirmed until somebody remembered otherwise. As a status the default falls the right way and the two places that DO need it have to say so.

**The sweep cancels through `cancel_booking()`, never by updating rows itself.** That is the only reason that function accepts a service context. Doing the update inline would be shorter and would skip §4.2, so the seat would come free and nobody on the waitlist would ever hear about it — worse than not freeing it. A seat that was only ever held is also never recorded as a *late* cancellation: no member should carry a black mark for a class they never paid for.

**How long the hold lasts is the studio's setting**, `dropin_payment_window_minutes`, beside the other timing rules. A 6am reformer class wants its seat back quickly and a quiet Sunday mat class does not.

**Deferrable is not a carve-out.** The instructor constraint is `DEFERRABLE INITIALLY IMMEDIATE`, so two instructors can swap two simultaneous classes inside one transaction — a valid end state that is refused statement by statement without it. The database still refuses to COMMIT a double-booking; it only tolerates the journey. The room constraint is left immediate as instructed, and has the same swap friction.

**`substitute_for` is historical; `instructor_id` is who teaches.** A class being subbed already stops counting against the original instructor, so no carve-out was needed for substitution — subbing somebody in is refused only when they genuinely cannot be in two places.

**A move that changes the arrangement owes a free cancellation.** More than `significant_move_hours`, or onto a different day in studio time, sets `bookings.free_cancel_until`, which `cancel_booking()` honours over the studio's cutoff. Decision 2's reasoning: they agreed to a time and the studio changed it, so charging them for cancelling is charging them for the studio's decision.

**Nothing moves on screen until the database has answered.** The calendar's first version applied the drag optimistically and reverted on refusal, which meant an accidental two-pixel drag visibly relocated a class with eight people in it before anyone was asked. The confirm now comes first, and it says how many members will be emailed.

**An undo withdraws the email rather than sending a second one.** Moving a class back within sixty seconds is read as a correction: the unsent `class_moved` rows are deleted and nothing new is queued. Any move also deletes the previous unsent notice for that class, because it describes a move that has been superseded.

**What cannot physically overlap is an exclusion constraint, not a check.** A room cannot hold two classes and a person cannot teach two at once. `occ_room_no_overlap` and `occ_instructor_no_overlap` are GiST exclusions — the first use of the `btree_gist` that migration 014 left installed — so they hold against every writer including an import, the seed and a hand-typed UPDATE. Both are partial: a cancelled class stops holding its room, and an open shift has no instructor to clash with but still holds its slot. The opclass is named explicitly (`extensions.gist_uuid_ops`) rather than resolved through search_path.

**Availability is a warning; overlap is a wall.** Decision 9's rule that a hard block gets worked around by not using the feature applies to availability, which is a judgement. It does not apply to two classes in one room, which is not.

**One function moves a class.** `move_occurrence()` backs the calendar's drag, its resize and the edit form. Before Decision 17 there was nothing to share — `createClass` was a bare insert with no conflict checking at all — so "the calendar must not bypass the form's rules" meant writing the rules, not reusing them. With members booked it refuses on the first call and returns the count; the caller confirms and the second call moves it and queues `class_moved`. A drag that silently emails forty people because a finger slipped is worse than one that asks.

**A derived column needs a trigger, not a default.** `class_occurrences.staffing` has a CHECK tying it to `instructor_id`, and no default can satisfy it — 'assigned' is wrong for a row inserted without an instructor and 'open' is wrong for one with. `tg_derive_staffing()` makes staffing follow `instructor_id` unless the caller already wrote a consistent pair. Without it the CHECK rejected ten existing suites and the seed, none of which know the column exists and none of which should have to.

**A library stylesheet imported from a component wins on source order.** react-big-calendar's CSS is imported inside the calendar component, which Next injects AFTER `globals.css` — so a bare `.rbc-today` override loses at equal specificity and the grid stayed the library's blue. Every override is scoped under `.rbc-calendar`, which wins on specificity rather than on order. Same lesson as the health chip's label, in reverse.

**Booking runs in one transaction with a row lock.** `select ... from class_occurrences where id = $1 for update` before reading `booked_count`. Application-level check-then-insert will overbook under load and is not acceptable.

**Money is integer cents plus an ISO currency code.** Never floats.

**A price is snapshotted, never referenced.** `memberships.price_cents` is copied from the plan at purchase (§7.1). Editing a plan must never reprice anyone already on it, and any screen that edits a plan has to say so, because "changed the price" reads like "changed what everyone pays" unless you tell people otherwise.

**A boolean authorisation helper must never return null.** `auth_role_in()` returns null for a caller who is staff of no studio, so `role in ('owner','manager')` is null, not false. RLS treats that as deny and is safe. plpgsql does not: `if not is_manager_up(x) then raise ... end if` skips its own raise, and the function carries on — and these functions are `SECURITY DEFINER`, so nothing is standing behind the guard. Every such guard in the codebase reads that way, and every one of them was open to any signed-in user who knew an id. Migration 020 fixes it in the helpers rather than at the call sites, because the call sites are the natural way to write it and the next one will be written the same way. When adding a helper, `coalesce(..., false)`.

**A guard that never fires looks exactly like a guard that passes.** The §5 tests for the importer used a front desk *of the same studio* — a real role, so the guard worked and the assertions passed. The caller who got through was the one with no staff row in that studio at all, which nothing exercised. When testing a permission, include a caller the check has never seen, not only a caller with the wrong role.

**A refused write does not raise — it changes nothing.** RLS blocks an INSERT with a WITH CHECK violation, which errors, but it blocks an UPDATE or DELETE by making the row invisible: PostgREST returns 200 and an empty array. Code that only checks `error` will report success having saved nothing. Check rows affected on every update and delete.

**A studio's timezone is validated in the database, not the form.** It governs every day boundary and every materialised occurrence, and a typo does not fail — `Europe/Pragu` is simply not a zone, and the studio's classes are quietly wrong from then on. `validate_iana_timezone()` (migration 015) checks against `pg_timezone_names` on insert and update, so the wizard, `provision_studio()` and any future import all meet the same rule. The UI offers `Intl.supportedValuesOf('timeZone')` with live UTC offsets so the value can only come from a list; that is convenience, not the guarantee.

**Time is `timestamptz` stored UTC.** Studio timezone governs display and all day boundaries. A 7am class stays 7am across DST — occurrences materialise by converting local time to UTC at generation, not by adding fixed intervals.

**Demo data is flagged, never inferred.** `generate_demo_data()` sets `is_demo` on every row it writes and `purge_demo_data()` clears the lot in one call. Fake members will sit in the same table as real ones; working out later which was which from names and email domains is not a plan.

**The palette is three tokens deep and every colour earned its role by measurement.** `app/globals.css` holds the lot; nothing in `app/` or `components/` may name a raw Tailwind colour. Two results decide most of the design and are not negotiable without redoing the sums: `#D9401A` is **4.47** on white, so coral borders, fills and sets large numerals but never a sentence — warnings are ink on `--coral-tint` with a coral rule; and `stone-400` is **2.41**, so `--ink-3` (4.59) is the floor for greying anything, including a class that has already happened.

**The health band is the only loud thing, and its loudness is rationed.** Full-bleed fills were built first and thrown away twice — most members are healthy, so the screen came out a wall of lime, and sorted by severity it came out a wall of coral. Healthy has no reason to carry (Decision 14 gives one to every band *except* healthy), so it renders as a chip and nothing more.

**The chip is a pill, and the colour lives in its dot.** A hard-cornered, tracked-out, fully saturated slab is the shape of an enum member, and twelve down a column read as a database column rather than as a remark about a person. Tinted fill, 6px dot, a hairline a step darker, a 2px shadow at 5%, sentence case, no letter-spacing. A dot is a non-text UI element and needs 3:1 against its own fill — lime manages **1.23** there and amber **1.54**, both being near-white by value, so the dot takes each band's deepest available value instead: `--lime-text` for healthy, `--coral` for at risk, and `--amber-deep` (#938228, amber carried 40% toward ink) for drifting, which is the one derived colour in the file and exists because the brand has no dark amber. Measured live: labels 15.08–18.12, dots 3.41–7.84.

**Softness is measured too.** Cards are 22px, tinted with `--accent-wash` and lifted on two shadows rather than outlined with a hairline — one wide soft shadow to float them, one tight dark one to give them an edge. The wash is the accent at **3.5%, not 4**: at 4% a deep purple on Warm takes `--ink-3` to 4.47, and `--ink-3` IS the muted floor. A background tint that costs a fifth of a point on every secondary line in the app is not worth having.

**A type ramp is a ratio, not a set of sizes.** Everything sat between 12 and 17px, which is why the cards read as paragraphs — nothing said "this is the thing you are looking for". The time on a class card is now 21px against 13px metadata. 21 and not 24 because it was measured: at 375px the card gives the time and its duration pill 243px, and at 24px the time alone was 185 and the pill wrapped.

**Every icon sits on a chip.** A bare glyph beside a 13px line is a mark on a page; the same glyph on a filled `--accent-chip` square is a component, and a column of them lines up on a grid instead of drifting with the text. The pill and chip labels take `--ink-2` (worst 5.92 on the tint) — `--ink-3` measures 3.72 there and fails.

**Member photographs are private; studio photographs are not.** `member-avatars` is a private bucket read through signed URLs, and `members.avatar_url` holds an object PATH rather than a URL. A logo and a class photograph are things a studio publishes; a member's face is not, and tenant one's data is production data. Instructor avatars stay public — the studio publishes those deliberately.

**The accent is a pair, never a single colour.** `bg-lime text-ink` was hard-coded in seven places in the member app: fine while the accent is our near-yellow lime, unreadable the moment a studio picks navy. `accentRamp()` now derives `solid` and `onSolid` together - the fill, and the ink-or-surface that was *measured* on it - and moves the fill only when neither could sit on it. Across 8 accents x 4 presets the worst pair is 4.54:1 and only 2 of 32 needed adjusting. A caller takes both or neither.

**An unbranded studio gets its own ink, never Studiior's lime.** `accent ?? "#BEF738"` in three files meant every studio that had not picked a colour - all of them on day one - wore our brand on its login screen, its today circle and every primary button. `neutralAccent(preset)` returns the preset's ink instead: a monochrome member app is a deliberate look, somebody else's brand is not. Migration 034 had already made this exact call for email, where the accent rule falls back to neutral grey.

**A gradient has two ends and text has to survive both.** The login field ran from the accent to the accent darkened toward ink, which on Bold - whose ink is nearly white - *lightens* it, and white text fell to 3.27. `accentGradient()` moves the second stop away from the text colour rather than toward the preset's ink, so it can only ever increase the contrast the first stop was measured for. Worst across 32 combinations: 4.54.

**The login screen is the studio's photograph, not a form on top of one.** Full bleed edge to edge, with the panel as a sheet anchored to the bottom and reaching both edges — rounded on the top corners only, hairline along the top only, and owning the home-indicator inset the tab bar owns elsewhere. A card floating with margins on four sides puts a frame around the picture and turns it into decoration behind a form. The logo and studio name sit over the photograph on the scrim, above the sheet.

**A logo goes on a near-white chip, never straight onto the photograph.** Most studio logos are a raster with a white background, so dropping one onto a picture leaves a white rectangle floating in it — and assuming transparency is assuming a PNG the studio may never have made. `object-contain`, not `cover`: a logo cropped to fill a square is a different logo.

**`login_image_url` is uploaded from `/branding`, same path as the logo.** It had existed since migration 029 with nothing writing it, so every studio fell through to the gradient and the frosted panel built for a photograph never rendered anywhere. The storage policy does the enforcing either way — the studio id is the first path segment. The 2 MB ceiling is the bucket's own `file_size_limit`, which is why the copy says so rather than letting a wide studio photo fail with a raw storage error. **Gaps:** neither the logo nor the login photo can be removed once set, only replaced.

**Opacity on text is a contrast change, not a styling choice.** The login sub-line was set in `onSolid` at 82%, which composites it toward the accent underneath and took terracotta-on-Warm to **3.61**. It is full opacity now (worst 4.54 across 32 combinations). Fading a colour that was measured at full strength is the same mistake as tinting coral until it nearly passes; over a photograph the scrim guarantees a dark ground, so a fade there costs nothing measurable.

**No backdrop-filter anywhere except the login screen over a photograph.** That is the one place with something behind the panel to refract; over a flat surface blur is fog with a compositor layer attached, and on a scrolling list it is paid for every frame. The login panel is dark-tinted rather than white, because white frosting over a photograph gives white text on a pale translucent field whose ratio is whatever the photograph is doing - tinting dark and sitting it in the scrim's darkest band makes the composite predictable. A studio with no photograph gets a solid panel over the accent gradient; there is nothing to refract there either.

**No backdrop-filter on cards.** Over a flat white row there is nothing behind a chip to refract, so glass renders as a grey smudge and costs a compositor layer for it. Depth comes from fill and two shadows - one tight for the edge, one wide and soft for the float. The tab bar is now the exception, and only because it floats over a scrolling gradient; see the member PWA section above.

**The row-size band has no wash; the hero does, and its chip goes white there.** The chip's fill is the band's tint, so a wash behind it leaves a pill dissolving into a bar — and a column of pale bars is the slab problem again in a weaker shade. On the hero the ground is worth keeping, so the chip takes `--surface` and lifts off it (1.20 against the wash, with a 1.48 border).

**A colour set in `globals.css` beats a Tailwind text utility.** Those classes are declared after `@tailwind utilities` and match on equal specificity, so source order decides. `.section-label` carried a `color` and silently repainted every health chip's label to `--ink-2`, dropping the at-risk chip from 6.42 to **2.70**. Utility classes there are not overrides; measure the rendered DOM rather than reading the markup.

**The member app is themed; the staff app is not.** A studio brands what its members see, not our back office — theming both would mean every support conversation starts with "what does yours look like". `themeVars()` is applied to the member subtree, never `:root`, and the staff body still measures `#FAFAF7` with a studio in Bold.

**A preset is a complete surface system, and every one of them was measured.** Four presets × six tokens, with the same floor as the staff app: muted text clears 4.5:1 on *both* the surface and the paper behind it. Calm's obvious sage grey `#6E796E` came out at **4.14** on its own paper and was darkened 10% toward ink to `#667066` (4.69 / 5.01) rather than shipped as a near-miss — the same call as coral not setting body text.

**An accent is stored raw and its ramp is derived, capped at 60% toward ink.** Raw for large fills, darkened step by step until it clears 4.5:1 for text, 12% over the surface for a tint. The cap is what makes the refusal real: past 60% it is not the studio's colour any more, it is ink wearing a hint of it, and shipping that silently is exactly the substitution this avoids. 2 of 28 sample pairs fall back, both on Calm, and the picker says so and shows what members will actually get. The derivation lives in `lib/theme.ts` alone — the live preview and the member app must agree, and two implementations of one contrast walk eventually will not.

**One login, many memberships — and Permissions line 267 was wrong about it.** It said a person who is a member of two studios "has two accounts, and no policy anywhere joins them". `auth.users` carries `users_email_partial_key`, a global unique index on email, so one address is one account project-wide; and `auth_member_studios()` returns a *set*, so it is exactly such a policy. Corrected in the doc. The consequence was live: `getMemberContext()` selected on `user_id` alone with `.maybeSingle()`, so a second membership made PostgREST error and the member PWA told those people they had no studio access. It is now scoped by the subdomain's slug — not by taking the first row, which would have hidden the bug and shown somebody the wrong studio's data.

**An email address names a member, so a match must wait for verification.** `members` is unique on `(studio_id, lower(email))`. If self-signup linked on an email match alone, anyone who knew a member's address could take their account and read their attendance and payment history. `claim_member_by_email()` reads `auth.users.email_confirmed_at` itself and refuses otherwise — in the function, not in the screen that calls it, because a check in the screen is a promise and a check in the function is the rule. `enable_confirmations` is on in `config.toml` for the same reason: a test that passes because verification was off proves nothing.

**Serial depth is the cost, not the number of queries.** One member Home render made 14 requests to Supabase, 7 of them strictly sequential — 1.75 s of pure latency from Manila to Frankfurt before anything rendered. It now makes 6, 2 deep. The staff app was 11 and 5, and is now 4 and 2. In both cases the removed *hops* were worth far more than the removed requests.

**A bootstrap carries what every page needs, and no more.** `member_bootstrap()` and `staff_bootstrap()` return the context plus the handful of things every screen reads. The billing screen's trial and grace dates are NOT in them: one screen needs those, and putting them in the bootstrap would make every other render pay for them.

**`getClaims()` verifies; `getSession()` does not.** getClaims checks the JWT signature locally with WebCrypto against a cached JWKS — measured: one JWKS fetch, then ~0.6 ms and zero requests per call, versus 52 ms and a network call every time for `getUser()`. A forged signature is rejected locally with "Invalid JWT signature". getSession, by contrast, reads the cookie and checks nothing, and is used nowhere.

It falls back to a network `getUser()` for symmetric HS256 keys, **silently**. This project signs ES256 on local and on hosted (checked against the hosted JWKS before relying on it), and `assertAsymmetricSigning()` warns once per process if that ever stops being true — otherwise it is the local-versus-hosted trap of migrations 006, 011 and 033 all over again, with no error and no failing test.

**Nothing decides who you are from a cookie.** Even where the claims are read locally, the member row comes from an RLS-scoped query: PostgREST verifies the signature on every request (forged and expired both 401 `PGRST301`), and `members_self` keys on `auth.uid()` from that verified claim, not on the filter the app passes. Asking for another member's row with a genuine token returns `[]`.

**Middleware resolves nothing.** It used to call `studio_by_slug()` on every matched request purely to 404 an unknown slug — a round trip to answer a question `app/member/layout.tsx` already answers on the same request. The 404 moved there.

**Ask the database what a member session returns before designing the screen that shows it.** Signed in as a real member: 76 check-ins visible, **0 with a class name**, 0 past occurrences, 0 rooms, 0 settings rows. `occ_member_read` is `status = 'scheduled'`, which is right for a schedule and wrong for a history — a class leaves the member's view the moment it runs. The History screen would have rendered seventy-six rows reading "Visit" and looked finished. The fix is narrow on purpose: readable if you have a booking or a check-in for it, not "all statuses", which would hand every member the studio's entire past schedule.

**A member-facing subset of a settings table is a function, not a policy.** RLS is row-level, so a read policy on `studio_settings` to expose the check-in window would also expose every fee, the morning brief time and the onboarding state. `studio_member_settings()` returns the six fields the app needs, the same shape as `studio_by_slug()`.

**The check-in code is an HMAC, not a row.** Member id plus a 30-second bucket, keyed by a per-studio secret the member cannot read, so it cannot be forged and a screenshot is worthless thirty seconds later. `resolve_checkin_code()` accepts the current bucket or the one before it, because a scan takes a moment and a code that dies mid-rotation is a member holding up a phone the desk has just rejected.

**Revoking from `PUBLIC` does not revoke from `authenticated` either.** This is the `anon` lesson from migrations 006 and 011, and it was repeated in full by migration 030: it ends with `revoke execute on function send_via_resend(...) from public`, which reads like closing the door and is not. Hosted default privileges name `authenticated` explicitly, so every function `postgres` creates in `public` is born with an `authenticated=X` grant. Five functions with no guard in them — including one returning the Resend API key in cleartext — were callable by any signed-in user for two migrations. **Name the roles: `from public, anon, authenticated`.**

**A drop-and-recreate re-opens what a revoke closed.** `create or replace` keeps a function's ACL; `drop` then `create` does not, and the new function is born with the hosted default grant again. Migration 034 has to change two signatures, so it re-applies 033's revokes at the bottom and then asserts, in the migration itself, that nothing it recreated is reachable by a client role. Any migration that drops a function owes the same.

**Revoke by OID, not by a hand-typed signature.** `revoke execute on function queue_notification(uuid,uuid,text,jsonb,text,timestamptz)` with one parameter wrong is not an error — it matches nothing and reports success. Migration 033 loops over `pg_proc` and revokes `p.oid::regprocedure`, and raises if it matched zero.

**An unsubscribe link is a deliverability control, not a legal one.** Transactional mail is exempt and three of our templates cannot be turned off at all — but a member who cannot find a way to turn *anything* off marks the message as spam, and those complaints land against a sending domain every studio shares. One annoyed member degrades delivery for all ten design partners. The footer therefore always links to `/settings`, and an email that cannot be switched off says so rather than offering a control that would do nothing.

**A preference is checked when the row is written, not when it is sent.** A notification a member opted out of is never queued, so no future worker can send it by forgetting to ask, and the queue is a list of things that may go out rather than a list of candidates. Three events have no opt-out at all — a cancelled class, a substituted instructor, a failed payment — because there is no reading of "I turned off emails" that makes it right to let somebody turn up to a class that is not running.

**`dedupe_key` stops a duplicate row; only a claim stops a duplicate send.** The unique index does nothing about two worker runs both picking up the same `scheduled` row. The worker claims with `for update skip locked` and flips to `sending` in the same statement, and delivery is two passes because pg_net is asynchronous — marking a row sent at post time would be recording a hope rather than a fact.

**A missing API key is an ordinary state and must not take the cron down.** A fresh local stack has none. The worker records it against the row as a failure with a readable reason and carries on; letting it raise would kill the job and lose every other studio's notifications too, which is what the test proves by reverting it.

**`composite IS NOT NULL` in plpgsql is true only when every field is non-null.** `queue_notification()` first returned the `notifications` row, so `queue_notification(...) is not null` read as false on success — a fresh row has a null `sent_at` — and every caller's counter came back zero while the rows were being written perfectly well. It returns a uuid now. Any function returning a row for a caller to null-check has this bug waiting in it.

**A background job needs a positive identity, never an absent one.** pg_cron runs with no JWT, so `auth.uid()` is null, `is_platform_admin()` is false and `is_manager_up()` is false — all correctly. The temptation is to let a null through, and that is precisely the hole migration 002 had and 020 finished closing: it would hand the job's powers to any caller PostgREST failed to identify. `is_service_context()` instead asks whether the effective role is one Postgres itself marks `rolsuper` or `rolbypassrls` — `postgres`, `service_role`, `supabase_admin` yes; `authenticated` and `anon` never, with or without a token. It reads `current_setting('role')` rather than `current_user`, because inside a SECURITY DEFINER function `current_user` is the owner and would answer "trusted" for everybody. `brief_schedule_test.sql` asserts an authenticated session with a null `auth.uid()` is still refused, so rewriting the guard as `auth.uid() is null` fails the suite.

**A function with an `on commit drop` temp table runs once per transaction.** Already true of `generate_demo_data()`, and it bit `generate_morning_brief()` the moment something looped over more than one studio: the scheduler runs every due studio in one transaction, the second hit `relation "_cand" already exists`, and with ten design partners nine briefs would have failed every morning while the first looked fine. Drop the table at the top of the function, not just at commit — and check `to_regclass` rather than `drop if exists`, which emits a NOTICE on every one of the ninety-six daily runs.

**Nothing AI-generated sends itself.** The model drafts, the owner approves. Hard architectural rule.

The brief is the same rule again and currently the stronger version of it: nothing here calls a model at all. Insights are read off the data and the summary is composed from the insights that survived the cap, so it can never describe something the owner cannot see underneath it. Every action is a link to a screen where a person does the thing.

**An insight without a working button is a bug, not a feature** — data model §9 says so and §11 repeats it. `action_payload` therefore carries the resolved `href`, and `brief_test.sql` matches every one against the routes this app actually serves rather than merely checking it is non-null. `challenge_opportunity` is implemented and switched **off** in config for exactly this reason: challenges have no screen, so its button would go nowhere. Turning it on is a config change once they ship.

**§11's dedupe key is (type, subject, date); the brief is stricter than that.** On real data a member whose card was declined cannot book, so she arrives as `payment_failed` and again as `retention_risk` — two of five slots for one person, and the second is downstream of the first. Only one insight per subject survives, the most severe. §11's own reason for the cap, that more than five and the owner stops reading, is the argument for it.

That rule reaches one step earlier than the AI. `message_draft_for()` composes and stops; the compose screen puts the draft in an editable field, and what gets queued is the field's contents, not the function's output. There is deliberately no code path from "compose" to "queued" that skips a person, and adding one would be the bug rather than the optimisation.

**A derived event must be written in both places or neither.** `rebuild_member_timeline()` deletes a member's events and re-derives them, so an event written only by the thing that caused it survives until the next rebuild and then disappears without trace — migration 021's own comment guessed such events would "append rather than rebuild", and they would not. `message_sent` is therefore written by `send_message()` *and* derived by the rebuild, field for field identically, so it appears at once and survives. Anything else that starts writing timeline events has the same obligation.

**Deletes are soft** via `status` / `archived_at`. Hard delete only for GDPR erasure.

**Credits derive from `credit_ledger`.** Never edited in place. `memberships.credits_remaining` is a cache written in the same transaction as the ledger row.

**An applied migration is immutable.** Once a migration has run against a hosted Supabase project, it is history: fix forward with a new migration, never edit the file in place. **This has now been broken three times — 062, 070 and 075 — and the first two times the symptom appeared weeks later as a screen that rendered nothing.** The third was caught by the tool the first two paid for, one day later rather than one month. **075 was not edited by hand; it was built up with `cat >>` across several steps while it was applied in between**, which is editing an applied migration however it is spelled — hosted recorded `20260830850000` after the first append and never looked at the file again, so the pending list, the report, the sweep and the rebuilds of `generate_occurrences` and `schedule_range` never reached it. A long migration gets written in a scratch file and moved into `supabase/migrations/` **once**. A local `db reset` replays the corrected file and passes; hosted keeps the draft forever. After any migration work, run `scripts/check-hosted-drift.sh` — the migration list will agree with itself while the definitions differ. A hosted database records which migrations it has applied and will not replay an edited one, so the file and the live schema silently diverge — and every environment that already ran the old version keeps it.

Until something is actually hosted, editing in place is safe and `db reset` replays from scratch, so migration 002's authorisation predicate was corrected in the file rather than patched over. **That grace expires the first time a migration reaches a hosted project.** After that the rule is absolute, including for a comment.

---

## Stack

Supabase (Postgres, RLS per tenant) · Next.js (staff app + member PWA) · Stripe Connect Standard, studio's own account — money never touches the platform · Vercel, auto-deploy on push.

Staff app at `app.studiior.com`. Member PWA at `{studio}.studiior.app`, per-studio branding, no app store. Notifications are email plus web push only; iOS push works post-install only.

---

## Workflow

```bash
supabase start                 # local stack
supabase db reset              # drop, replay all migrations, run supabase/seed.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/rls_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/book_class_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/booking_concurrency_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/checkin_window_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/plan_management_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/onboarding_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/health_score_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/importer_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/timeline_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/messages_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/brief_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/brief_schedule_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/member_app_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/member_accounts_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/notifications_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/stripe_connect_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/manual_payments_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/platform_billing_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/scheduling_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/cover_and_commitment_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/occurrence_generation_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/archive_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/member_records_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/qualifications_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/assignment_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/demo_purge_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/series_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/instructor_self_service_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/onboarding_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/health_score_test.sql
```

`db reset` before every test run. Testing against accumulated local state hides migrations that fail on a clean install. The suites use disjoint UUID spaces and email domains, so they can run in any order after one reset — **check which space is free before writing a new one**: `1111` seed and checkin and plans, `2222` brief, `3333` messages, `dddd` brief scheduler, `eeee` member app, `abab` member accounts, `1313` notifications, `5757` stripe, `cafe` manual payments, `b111` platform billing, `f00d` scheduling, `c0de` cover and commitments, `0ccc` occurrence generation, `0a11` archive and delete, `d0c5` notes goals and documents, `9ca1` qualifications, `a55e` assignment, `deed` demo purge, `5e21` series, `1f5e` instructor self-service, `4444` timeline, `5555` importer, `6666` health, `7777` plans, `8888` onboarding, `9999` checkin, `aaaa` rls. The brief suite was written into 7777, passed alone, and collided with plan management on `auth.users` the first time both ran on one reset — but each will refuse to run twice without a reset, because its own fixtures are already there.

Migrations need timestamp filenames (`YYYYMMDDHHMMSS_name.sql`) or the CLI skips them silently, which looks exactly like a push that worked.

Never run any of the seven suites against production. They create roles, insert fixtures, and the concurrency suite opens 50 connections.

---

## Known issues

`btree_gist` now lives in `extensions`, not `public`. It is installed but unused — no GiST index, no exclusion constraint. If you later add one (room double-booking is the obvious candidate), its operators resolve through the database search_path, which includes `extensions`.

**Seed data hides whole categories of state.** `supabase/seed.sql` gives every user a `studio_staff` row, so no seeded account has ever exercised "signed in, staff of nothing" — and a platform admin is exactly that by design. `getStaffContext()` returned null for them, callers read null as "not signed in", and sign-in looped on `app.studiior.com` while every local test passed. The suites did not catch it either, for the same reason: their fixtures also give everyone a staff row.

Before trusting a green run, ask what state the seed cannot produce. Empty studios, users with no membership anywhere, a studio with no owner, a plan nobody bought, a member with no bookings. If a code path keys off "no rows", the seed almost certainly has rows.

The same blind spot produced migration 020: every fixture in every suite gives every caller a staff row *in the studio under test*, so `is_manager_up()` was never asked about a studio the caller is nothing to, and nothing ever saw it return null.

**A fixture built through `provision_studio()` is a different studio every run.** It mints a `gen_random_uuid()`, and `generate_demo_data()` derives every member, booking and attendance hash from the studio id — so the health suite was silently testing a new dataset each time and passing on luck. It passed for weeks and then failed with *"Luntian (booking drift) expected drifting, got healthy"*, which is not a regression but a different draw. Its studio id is now pinned. Any suite that generates demo data has to pin one.

**`generate_demo_data()` runs once per transaction and once per studio.** Its temp tables are `on commit drop`, so two calls in one transaction collide on `_d_room`. It also used to select the check-ins it writes by `is_demo` alone, with no studio — which meant the second studio on any database re-selected the first one's bookings and died on `check_ins_booking_id_key`. Fixed, but the shape of the mistake is worth remembering: `is_demo` is a marker, never a tenant boundary. The tenant boundary is `studio_id`, every time.



`btree_gist` internals throw grant warnings on every `db reset`. Cosmetic. Fix by scoping grants to own functions rather than `all functions in schema public`.
