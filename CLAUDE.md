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

Twenty-eight migrations, applying clean from `supabase db reset`:

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
- **029** studio branding for the member app: `theme_preset` (warm/clean/calm/bold), a shape-checked `accent_color`, a `studio-branding` storage bucket whose write policy keys on the studio id in the first path segment, and `studio_by_slug()` fixed forward to carry the branding — the login screen and the tab title are both branded before anyone signs in
- **028** Decision 15: §2.1 rule 5 passes `lead` as well as `active`, and a second guard after §2.2 refuses a lead resolving to anything but `drop_in`. Replaced `book_class()` forward **from the live definition**, not from 002's text — 003 added a fifth parameter, so re-issuing 002's four-argument signature creates a second overload and every call fails as ambiguous
- **027** member accounts: `member_invites` (hashed, single-use, one live per member), `claim_member_account()` for the invite path, and `claim_member_by_email()` for self-signup — which refuses until `auth.users.email_confirmed_at` is set
- **025** the member app's missing half: `occ_member_own_read` (a member may read a class at any status if they have a booking or check-in for it), `rooms_member_read`, `studio_member_settings()`, the rotating check-in code, `cancel_booking()` per §3.1, and `respond_to_offer()`. Written after asking a real member session what it returns, not after designing screens
- **024** the clock behind the brief: `is_service_context()`, `run_due_morning_briefs()`, and a pg_cron job every 15 minutes. `studios_due_for_brief()` had existed since 023 with nothing calling it, so no brief ever generated on its own
- **023** the Morning Brief: `insight_config` (every §11 threshold as a row a studio can move), `generate_morning_brief()`, `brief_summary()`, `studios_due_for_brief()` and `set_insight_status()`. Writes `ai_insights` and `morning_briefs`, which had existed since 001 with nothing writing them. No model is called and `model` / `prompt_version` stay null — a row naming a model it never saw would be worse than an empty column
- **022** `messages` and `message_templates`: one person writing to one member, per Permissions §12 — owner, manager and front desk, never instructors. Nothing sends. `send_message()` moves a draft to `queued` and stops, so a transport becomes one adapter reading queued rows rather than a refactor. `message_draft_for()` composes from the band's reason, one draft per reason, out of a table a studio can later edit
- **020** `is_manager_up()` and `is_desk_up()` return false rather than null for a caller who is staff of no studio. `auth_role_in()` gives null, `null in (...)` is null, and every guard in the codebase is written `if not is_manager_up(x) then raise` — which does nothing against a null. Harmless in the ~110 policies that use these (a policy denies on null); a hole in every SECURITY DEFINER function that used them as a gate. See the rule below

Fourteen suites, **542 assertions**, all passing from a clean `db reset`:

| Suite | Asserts | Covers |
|---|---|---|
| `test/rls_test.sql` | 36 | tenant isolation, role boundaries, restricted views |
| `test/book_class_test.sql` | 57 | authorisation, gate reason codes, payment resolution, overrides, comp |
| `test/booking_concurrency_test.sql` | 20 | 50 simultaneous bookings against a 10-seat class |
| `test/checkin_window_test.sql` | 11 | §8 check-in window bounds, the settings that move them, the escape hatch |
| `test/plan_management_test.sql` | 56 | Permissions §9 on plans and templates, the delete guard, price snapshotting |
| `test/onboarding_test.sql` | 71 | platform-admin boundary, invite single-use and expiry, atomic acceptance, derived checklist, the stranded-user guards |
| `test/health_score_test.sql` | 59 | Decision 14's five signals in priority order, every band including `new` and `insufficient_history`, reasons carrying real numbers |
| `test/member_accounts_test.sql` | 31 | an unverified email cannot claim an existing member, a used or expired token fails, one login holds two memberships without either seeing the other, a lead books drop-in only |
| `test/member_app_test.sql` | 32 | history joins to real classes while someone else's past class stays hidden, the code rotates and only the desk resolves it, cancelling returns or consumes the credit and always frees the seat |
| `test/brief_schedule_test.sql` | 32 | a studio past its send time is picked up and one that is not is skipped, a second run the same day is a no-op, a half-finished run retries, and an authenticated caller with no JWT is still refused |
| `test/brief_test.sql` | 25 | the cap holds at five when twelve qualify, a dismissed subject stays gone seven days and comes back on the eighth, every `action_payload` href matches a route the app serves, retention_risk agrees with the band |
| `test/messages_test.sql` | 34 | one draft per reason, sending queues and never sends, the journey learns once, §12 including an instructor and a stranger |
| `test/timeline_test.sql` | 20 | derivation matches source, rebuilding twice does not double, a stranger and a front desk are both refused |
| `test/importer_test.sql` | 58 | dry run changes nothing, commit is atomic, rollback is exact and refuses when it cannot be clean, no notifications or challenge progress from imported attendance, §5 including a caller who is staff of another studio |

`supabase/seed.sql` runs automatically on `db reset` and seeds Reform Collective as tenant one — **synthetic data only**, every address `@example.com`. One studio, one location, two rooms, four class types, three instructors, owner/manager/front-desk/instructor logins, four plans, a thirteen-class week materialised 26 weeks back and 4 weeks forward, and 30 members across six cohorts with attendance to match. The cohorts exist so the AI features have something real to read: five members drifting into `retention_risk`, four `new_member_stalled`, one `past_due` membership, four who never returned after one class. Attendance is generated from a deterministic hash rather than `random()`, so every reset produces an identical database and a misbehaving query can be reproduced. It also seeds the CRM tables — notes (including a `managers_only` one, so that policy has a fixture), goals, tags — and rebuilds the timeline at the end. Those three tables had existed since migration 001 with nothing ever writing to them, which meant every CRM section rendered its empty state in every environment and an empty state was indistinguishable from a broken query.

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

Studios brand the member app at `/branding`, owner only — four presets and one accent, with a live preview that is a real member Home rather than swatches. `brand_color` stays dead and is superseded by `accent_color`.

The member PWA is built at `{slug}.studiior.app` — five screens on a bottom tab bar: home, book, check in, history, plan. Phone-first rather than a smaller staff app: body is 15px not 14, nothing interactive is under 44px, the primary action is 56px and there is one of it. Home leads with the next class, and inside the §8 check-in window that card stops describing the class and becomes the way in. Booking and cancelling go through `book_class()` and `cancel_booking()`; a class you are in reads as a different row rather than wearing a tick.

It is branded as the studio, including the browser tab, the bookmark and the name iOS uses on a home screen — `app/member/layout.tsx` titles it from `studio_by_slug()`. The word "Studiior" appears nowhere a member can see. `brand_color` is deliberately unused: an arbitrary hex with unverified contrast driving text or fills would silently break every ratio the palette was measured for, so identity is carried by the logo and the name.

**Next:** selling a plan to a member (§9 gives front desk that, unlike editing), then cancellation and the waitlist promotion flow.

---

## Rules that are not negotiable

**RLS is the security boundary.** A permission that exists only in React is not a permission. Every rule in the permissions doc is a policy. Instructor access to revenue is denied at the policy level, not by hiding menu items.

**Every table gets RLS and a grant.** RLS decides which rows; grants decide whether the role may touch the table at all. Both, or the table is either closed to everyone or open to everyone. See migration 001 §16 — but read migration 005 with it: §16 claims there is no pre-login surface, and since migration 004 there is exactly one, `studio_by_slug()`.

**Functions are closed by default, because PostgreSQL's default is the opposite.** A new function is executable the moment it is created. Withholding a grant does nothing; you have to revoke. Say who may execute, every time.

**Revoking from `PUBLIC` is not the same as revoking from `anon`, and only hosted can tell you.** The hosted platform ships default privileges naming `anon` explicitly, so every function created by `postgres` in `public` is born with an `anon=X` grant. The local stack does not do this. Migration 006 revoked from `PUBLIC`, passed every local check, and left eight functions anon-callable in production for five migrations; 011 revoked from `anon` and flipped the hosted default so the next one is not born open.

The lesson is not about one grant. **`supabase db reset` cannot verify grants** — local and hosted have different default ACLs, so the tests agree with the wrong answer. After any migration that creates a function or touches privileges, run the advisor query against the hosted project, not just locally:

```bash
supabase db query --linked "select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute');"
```

The only names of ours that belong in that output are `studio_by_slug(text)`, `studio_invite_preview(text)` and `accept_studio_invite(text,text,text)` — the three pre-login surfaces. As of migration 014 that query returns exactly those three on hosted, with no filtering needed.

Note what migration 013 found: the query has to enumerate what is *actually there* on hosted, not what this repo creates. `rls_auto_enable()` is installed by the platform, exists on no local stack, and sat anon-callable through migration 011 because 011 only checked its own list.

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

**No backdrop-filter anywhere.** Over a flat white row there is nothing behind a chip to refract, so glass renders as a grey smudge and costs a compositor layer for it. Depth comes from fill, hairline and a 2px shadow.

**The row-size band has no wash; the hero does, and its chip goes white there.** The chip's fill is the band's tint, so a wash behind it leaves a pill dissolving into a bar — and a column of pale bars is the slab problem again in a weaker shade. On the hero the ground is worth keeping, so the chip takes `--surface` and lifts off it (1.20 against the wash, with a 1.48 border).

**A colour set in `globals.css` beats a Tailwind text utility.** Those classes are declared after `@tailwind utilities` and match on equal specificity, so source order decides. `.section-label` carried a `color` and silently repainted every health chip's label to `--ink-2`, dropping the at-risk chip from 6.42 to **2.70**. Utility classes there are not overrides; measure the rendered DOM rather than reading the markup.

**The member app is themed; the staff app is not.** A studio brands what its members see, not our back office — theming both would mean every support conversation starts with "what does yours look like". `themeVars()` is applied to the member subtree, never `:root`, and the staff body still measures `#FAFAF7` with a studio in Bold.

**A preset is a complete surface system, and every one of them was measured.** Four presets × six tokens, with the same floor as the staff app: muted text clears 4.5:1 on *both* the surface and the paper behind it. Calm's obvious sage grey `#6E796E` came out at **4.14** on its own paper and was darkened 10% toward ink to `#667066` (4.69 / 5.01) rather than shipped as a near-miss — the same call as coral not setting body text.

**An accent is stored raw and its ramp is derived, capped at 60% toward ink.** Raw for large fills, darkened step by step until it clears 4.5:1 for text, 12% over the surface for a tint. The cap is what makes the refusal real: past 60% it is not the studio's colour any more, it is ink wearing a hint of it, and shipping that silently is exactly the substitution this avoids. 2 of 28 sample pairs fall back, both on Calm, and the picker says so and shows what members will actually get. The derivation lives in `lib/theme.ts` alone — the live preview and the member app must agree, and two implementations of one contrast walk eventually will not.

**One login, many memberships — and Permissions line 267 was wrong about it.** It said a person who is a member of two studios "has two accounts, and no policy anywhere joins them". `auth.users` carries `users_email_partial_key`, a global unique index on email, so one address is one account project-wide; and `auth_member_studios()` returns a *set*, so it is exactly such a policy. Corrected in the doc. The consequence was live: `getMemberContext()` selected on `user_id` alone with `.maybeSingle()`, so a second membership made PostgREST error and the member PWA told those people they had no studio access. It is now scoped by the subdomain's slug — not by taking the first row, which would have hidden the bug and shown somebody the wrong studio's data.

**An email address names a member, so a match must wait for verification.** `members` is unique on `(studio_id, lower(email))`. If self-signup linked on an email match alone, anyone who knew a member's address could take their account and read their attendance and payment history. `claim_member_by_email()` reads `auth.users.email_confirmed_at` itself and refuses otherwise — in the function, not in the screen that calls it, because a check in the screen is a promise and a check in the function is the rule. `enable_confirmations` is on in `config.toml` for the same reason: a test that passes because verification was off proves nothing.

**Ask the database what a member session returns before designing the screen that shows it.** Signed in as a real member: 76 check-ins visible, **0 with a class name**, 0 past occurrences, 0 rooms, 0 settings rows. `occ_member_read` is `status = 'scheduled'`, which is right for a schedule and wrong for a history — a class leaves the member's view the moment it runs. The History screen would have rendered seventy-six rows reading "Visit" and looked finished. The fix is narrow on purpose: readable if you have a booking or a check-in for it, not "all statuses", which would hand every member the studio's entire past schedule.

**A member-facing subset of a settings table is a function, not a policy.** RLS is row-level, so a read policy on `studio_settings` to expose the check-in window would also expose every fee, the morning brief time and the onboarding state. `studio_member_settings()` returns the six fields the app needs, the same shape as `studio_by_slug()`.

**The check-in code is an HMAC, not a row.** Member id plus a 30-second bucket, keyed by a per-studio secret the member cannot read, so it cannot be forged and a screenshot is worthless thirty seconds later. `resolve_checkin_code()` accepts the current bucket or the one before it, because a scan takes a moment and a code that dies mid-rotation is a member holding up a phone the desk has just rejected.

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

**An applied migration is immutable.** Once a migration has run against a hosted Supabase project, it is history: fix forward with a new migration, never edit the file in place. A hosted database records which migrations it has applied and will not replay an edited one, so the file and the live schema silently diverge — and every environment that already ran the old version keeps it.

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
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/onboarding_test.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/health_score_test.sql
```

`db reset` before every test run. Testing against accumulated local state hides migrations that fail on a clean install. The suites use disjoint UUID spaces and email domains, so they can run in any order after one reset — **check which space is free before writing a new one**: `1111` seed and checkin and plans, `2222` brief, `3333` messages, `dddd` brief scheduler, `eeee` member app, `abab` member accounts, `4444` timeline, `5555` importer, `6666` health, `7777` plans, `8888` onboarding, `9999` checkin, `aaaa` rls. The brief suite was written into 7777, passed alone, and collided with plan management on `auth.users` the first time both ran on one reset — but each will refuse to run twice without a reset, because its own fixtures are already there.

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
