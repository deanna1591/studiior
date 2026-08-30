# STUDIIOR V1 — DATA MODEL

**Version:** 1.1 (reconstructed, patched for Decisions 9–11)
**Status:** Blocks all migrations
**Scope:** The seven core modules in the V1 Product Bible, Chapter 8. Nothing from the Chapter 7 exclusion list is modelled here.

> **Reconstruction note.** Recovered from the roadmap session. Sections 2–14 are verbatim. Section 3 `studios` / `studio_settings` and the `locations` table are marked **[RECONSTRUCTED]** — verify these against your original before running migration 001. Everything else is as originally written, plus the two patches noted in §15.

---

## 1. Decisions this schema encodes

| Decision | Choice |
|---|---|
| Tenancy | Single database, `studio_id` on every tenant table, enforced by RLS |
| Payments | Studio's own Stripe account via Connect Standard. All Stripe objects live on the **connected** account |
| Member surface | One codebase, per-studio branded PWA on a studio subdomain |
| Notifications | Email + Web Push. No SMS in V1 |
| Recurring classes | Series definition + materialised occurrences. Bookings attach to occurrences |
| Waitlist | A booking `status`, not a separate queue table |
| Money | Integer cents + ISO currency. Never floats |
| Deletes | Soft delete via `status` / `archived_at`. Hard delete only for GDPR erasure |
| Time | `timestamptz` everywhere, stored UTC. Studio timezone governs display and "day" boundaries for reporting |
| IDs | `uuid` primary keys, `gen_random_uuid()` |

Every table also carries `created_at timestamptz not null default now()` and, where mutable, `updated_at` maintained by trigger. Omitted below for brevity.

---

## 2. Enums

```sql
create type staff_role         as enum ('owner','manager','instructor','front_desk');
create type member_status      as enum ('lead','active','inactive','archived');
create type note_category      as enum ('general','injury','medical','preference','admin');
create type series_status      as enum ('active','ended','cancelled');
create type occurrence_status  as enum ('scheduled','cancelled','completed');
create type booking_status     as enum ('booked','waitlisted','cancelled','late_cancelled','attended','no_show');
create type booking_source     as enum ('member','staff','front_desk','import');
create type payment_source     as enum ('membership','class_pack','drop_in','comp','gift_card');
create type checkin_method     as enum ('qr','staff','kiosk','self');
create type plan_type          as enum ('recurring','class_pack','drop_in','trial');
create type billing_interval   as enum ('week','month','quarter','year');
create type membership_status  as enum ('trialing','active','past_due','frozen','cancelled','expired');
create type payment_status     as enum ('pending','succeeded','failed','refunded','partially_refunded');
create type credit_reason      as enum ('purchase','booking','cancellation_refund','expiry','freeze_adjustment','manual');
create type challenge_type     as enum ('class_count','streak','class_type_count');
create type challenge_status   as enum ('draft','scheduled','active','ended','archived');
create type insight_status     as enum ('new','actioned','dismissed','expired');
create type notif_channel      as enum ('email','push','in_app');
create type notif_status       as enum ('scheduled','sent','delivered','failed','cancelled');
create type import_status      as enum ('uploaded','validating','dry_run_complete','importing','complete','failed','rolled_back');

-- PATCH, Decision 11
create type challenge_audience as enum ('member','instructor');
```

---

## 3. Studio & identity

```sql
-- [RECONSTRUCTED — verify columns against original]
create table studios (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  slug              text not null unique,          -- subdomain: {slug}.studiior.app
  custom_domain     text unique,
  timezone          text not null,                 -- IANA
  currency          char(3) not null,
  country           char(2),
  logo_url          text,
  brand_color       text,
  stripe_account_id text,                          -- Connect Standard, owner-visible only
  status            text not null default 'active',
  archived_at       timestamptz
);

-- [RECONSTRUCTED — verify against original]
create table studio_settings (
  studio_id                uuid primary key references studios on delete cascade,
  booking_window_days      int not null default 30,
  cancellation_window_hours int not null default 12,
  late_cancel_fee_cents    int not null default 0,
  no_show_fee_cents        int not null default 0,
  max_bookings_per_day     int,
  waitlist_offer_minutes   int not null default 30,
  waitlist_auto_accept     boolean not null default false,
  payment_grace_days       int not null default 7 check (payment_grace_days between 0 and 30),
  sub_late_free_cancel     boolean not null default true,
  waiver_text              text,
  waiver_required          boolean not null default true
);

-- Dormant in V1: exactly one row per studio, no UI, no multi-location logic.
-- [RECONSTRUCTED]
create table locations (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios on delete cascade,
  name       text not null,
  address    jsonb,
  timezone   text,
  is_primary boolean not null default true,
  status     text not null default 'active'
);
create unique index locations_one_primary
  on locations (studio_id) where is_primary;

-- id == auth.users.id
create table profiles (
  id          uuid primary key references auth.users on delete cascade,
  email       text not null,
  full_name   text,
  avatar_url  text,
  phone       text
);

create table studio_staff (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  user_id     uuid references profiles on delete set null,
  email       text not null,
  role        staff_role not null,
  status      text not null default 'active',  -- active | invited | disabled
  invited_at  timestamptz,
  joined_at   timestamptz,
  unique (studio_id, user_id),
  unique (studio_id, lower(email))
);

-- Instructors are not always staff logins (subs, contractors)
create table instructors (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  staff_id       uuid references studio_staff on delete set null,
  display_name   text not null,
  bio            text,
  avatar_url     text,
  color          text,
  certifications jsonb not null default '[]',
  status         text not null default 'active'
);

create table rooms (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  location_id uuid not null references locations on delete cascade,
  name        text not null,
  capacity    int not null check (capacity > 0),
  color       text,
  status      text not null default 'active'
);
```

---

## 4. Members & CRM

```sql
create table members (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  user_id           uuid references profiles on delete set null,  -- set when they claim a login
  first_name        text not null,
  last_name         text not null,
  email             text not null,
  phone             text,
  date_of_birth     date,
  avatar_url        text,
  address           jsonb,
  emergency_contact jsonb,                                  -- {name, relationship, phone}
  status            member_status not null default 'active',
  joined_on         date not null default current_date,
  source            text,                                   -- referral | walk-in | web | import
  marketing_opt_in  boolean not null default false,
  waiver_signed_at  timestamptz,
  first_visit_at    timestamptz,
  last_visit_at     timestamptz,
  lifetime_visits   int not null default 0,
  current_streak    int not null default 0,
  archived_at       timestamptz,
  unique (studio_id, lower(email))
);

create table member_tags (
  id        uuid primary key default gen_random_uuid(),
  studio_id uuid not null references studios on delete cascade,
  name      text not null,
  color     text,
  unique (studio_id, lower(name))
);

create table member_tag_assignments (
  member_id uuid not null references members on delete cascade,
  tag_id    uuid not null references member_tags on delete cascade,
  studio_id uuid not null references studios on delete cascade,
  primary key (member_id, tag_id)
);

create table member_notes (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  member_id      uuid not null references members on delete cascade,
  author_user_id uuid references profiles on delete set null,
  category       note_category not null default 'general',
  body           text not null,
  active         boolean not null default true,   -- injuries resolve
  pinned         boolean not null default false,  -- surfaces on class roster
  managers_only  boolean not null default false
);

create table member_goals (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  title         text not null,
  target_type   text not null,        -- class_count | streak_days | custom
  target_value  int,
  current_value int not null default 0,
  target_date   date,
  completed_at  timestamptz,
  status        text not null default 'active'
);
```

### Member Journey Timeline

The signature feature. Written by one application-layer service, never by scattered triggers, so it is testable and replayable.

```sql
create table timeline_events (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  member_id      uuid not null references members on delete cascade,
  type           text not null,        -- joined | booked | attended | cancelled | payment |
                                       -- membership_changed | challenge_joined | challenge_completed |
                                       -- achievement | note_added | goal_completed | message_sent
  occurred_at    timestamptz not null,
  title          text not null,
  description    text,
  actor_user_id  uuid references profiles on delete set null,
  ref_table      text,
  ref_id         uuid,
  metadata       jsonb not null default '{}'
);
create index on timeline_events (studio_id, member_id, occurred_at desc);
```

---

## 5. Scheduling

A **series** is the rule; an **occurrence** is the bookable thing.

```sql
create table class_types (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  name             text not null,
  description      text,
  duration_minutes int not null,
  default_capacity int not null,
  difficulty       text,
  color            text,
  status           text not null default 'active'
);

create table class_series (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios on delete cascade,
  location_id         uuid not null references locations on delete cascade,
  class_type_id       uuid references class_types on delete set null,
  name                text not null,
  description         text,
  instructor_id       uuid references instructors on delete set null,
  room_id             uuid references rooms on delete set null,
  capacity            int not null check (capacity > 0),
  duration_minutes    int not null,
  difficulty          text,
  rrule               text not null,     -- RFC 5545
  starts_on           date not null,
  ends_on             date,              -- null = open ended
  time_of_day         time not null,
  booking_window_days int,               -- overrides studio default
  status              series_status not null default 'active',
  created_by          uuid references profiles on delete set null
);

create table class_occurrences (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  location_id      uuid not null references locations on delete cascade,
  series_id        uuid references class_series on delete cascade,   -- null = one-off
  class_type_id    uuid references class_types on delete set null,
  name             text not null,
  description      text,
  instructor_id    uuid references instructors on delete set null,
  substitute_for   uuid references instructors on delete set null,   -- original instructor if subbed
  room_id          uuid references rooms on delete set null,
  capacity         int not null check (capacity > 0),
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  status           occurrence_status not null default 'scheduled',
  is_exception     boolean not null default false,  -- edited away from its series
  booked_count     int not null default 0,
  waitlist_count   int not null default 0,
  cancelled_at     timestamptz,
  cancellation_reason text,
  instructor_notes text
);
create unique index on class_occurrences (series_id, starts_at) where series_id is not null;
create index on class_occurrences (studio_id, starts_at);
create index on class_occurrences (studio_id, instructor_id, starts_at);
```

**Generation.** A nightly job materialises occurrences for a rolling 12-month horizon per series, plus immediately on series create/edit. Editing a series offers *this occurrence only* / *this and future* / *entire series*; the first sets `is_exception = true` on that row and leaves it untouched by regeneration.

### Instructor availability — PATCH, Decision 9

```sql
create table instructor_availability (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  instructor_id  uuid not null references instructors on delete cascade,
  day_of_week    int check (day_of_week between 0 and 6),  -- null on dated exceptions
  starts_at_time time,
  ends_at_time   time,
  effective_from date,
  effective_to   date,
  exception_date date,                                     -- null on recurring patterns
  is_available   boolean not null default true,            -- false = blackout on that date
  note           text,
  created_by     uuid references profiles on delete set null,
  check ((day_of_week is not null) <> (exception_date is not null))
);
create index on instructor_availability (studio_id, instructor_id, day_of_week);
create index on instructor_availability (studio_id, exception_date) where exception_date is not null;
```

**No foreign key from `class_occurrences` to this table, deliberately.** Availability is an input to future assignment only. Editing availability never unassigns an instructor from an occurrence they are already on, never flags it, never notifies. Assigning an instructor outside their availability is permitted with a UI warning; it is not blocked at the database level.

---

## 6. Bookings, waitlist, check-in

```sql
create table bookings (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  occurrence_id     uuid not null references class_occurrences on delete cascade,
  member_id         uuid not null references members on delete cascade,
  status            booking_status not null default 'booked',
  source            booking_source not null default 'member',
  payment_source    payment_source,
  membership_id     uuid references memberships on delete set null,
  credit_entry_id   uuid,                       -- credit_ledger row that paid for this
  waitlist_position int,
  booked_at         timestamptz not null default now(),
  cancelled_at      timestamptz,
  cancelled_by      uuid references profiles on delete set null,
  is_late_cancel    boolean not null default false,
  fee_charged_cents int not null default 0
);

-- A member may hold at most one live booking per occurrence
create unique index bookings_one_live_per_member
  on bookings (occurrence_id, member_id)
  where status in ('booked','waitlisted','attended','no_show');

create index on bookings (studio_id, member_id, booked_at desc);
create index on bookings (occurrence_id, status, waitlist_position);

create table waitlist_offers (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  booking_id    uuid not null references bookings on delete cascade,
  occurrence_id uuid not null references class_occurrences on delete cascade,
  offered_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  responded_at  timestamptz,
  outcome       text        -- accepted | declined | expired | withdrawn
);
create index on waitlist_offers (expires_at) where outcome is null;

create table check_ins (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  booking_id    uuid not null unique references bookings on delete cascade,
  member_id     uuid not null references members on delete cascade,
  occurrence_id uuid not null references class_occurrences on delete cascade,
  checked_in_at timestamptz not null default now(),
  method        checkin_method not null,
  checked_in_by uuid references profiles on delete set null
);
```

### Concurrency rule — non-negotiable

Booking, cancellation and waitlist promotion all run inside a single Postgres function that takes `select ... from class_occurrences where id = $1 for update` before reading `booked_count`. Capacity is checked and `booked_count` incremented in the same transaction. Application-level "check then insert" **will** overbook under load and is not acceptable.

---

## 7. Memberships, packs & payments

```sql
create table membership_plans (
  id                      uuid primary key default gen_random_uuid(),
  studio_id               uuid not null references studios on delete cascade,
  name                    text not null,
  description             text,
  type                    plan_type not null,
  price_cents             int not null check (price_cents >= 0),
  currency                char(3) not null,
  billing_interval        billing_interval,        -- recurring only
  billing_interval_count  int not null default 1,
  credits                 int,                     -- null on 'recurring' = unlimited
  credits_per_period      int,                     -- e.g. 8 classes per month
  validity_days           int,                     -- pack expiry
  signup_fee_cents        int not null default 0,
  commitment_months       int not null default 0,
  cancellation_notice_days int not null default 0,
  freeze_allowed          boolean not null default true,
  max_freeze_days         int,
  booking_window_days     int,                     -- override
  max_bookings_per_day    int,                     -- override
  restrictions            jsonb not null default '{}',  -- {class_type_ids:[], peak_only:false}
  stripe_product_id       text,
  stripe_price_id         text,
  visibility              text not null default 'public',  -- public | hidden | staff_only
  status                  text not null default 'active',
  sort_order              int not null default 0
);

create table memberships (
  id                     uuid primary key default gen_random_uuid(),
  studio_id              uuid not null references studios on delete cascade,
  member_id              uuid not null references members on delete cascade,
  plan_id                uuid not null references membership_plans,
  status                 membership_status not null,
  price_cents            int not null,              -- snapshot at purchase
  currency               char(3) not null,
  starts_on              date not null,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  renews_on              date,
  expires_on             date,                      -- packs
  credits_remaining      int,
  credits_reset_at       timestamptz,
  auto_renew             boolean not null default true,
  freeze_start           date,
  freeze_end             date,
  freeze_days_used       int not null default 0,
  cancel_at              date,
  cancelled_at           timestamptz,
  cancellation_reason    text,
  stripe_customer_id     text,
  stripe_subscription_id text
);
create index on memberships (studio_id, status);
create index on memberships (studio_id, renews_on) where status = 'active';

create table membership_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  membership_id uuid not null references memberships on delete cascade,
  type          text not null,   -- created | renewed | frozen | unfrozen | upgraded | downgraded | cancelled | expired | payment_failed
  from_status   membership_status,
  to_status     membership_status,
  effective_at  timestamptz not null default now(),
  actor_user_id uuid references profiles on delete set null,
  metadata      jsonb not null default '{}'
);

create table credit_ledger (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  membership_id uuid references memberships on delete set null,
  delta         int not null,
  reason        credit_reason not null,
  booking_id    uuid references bookings on delete set null,
  balance_after int not null,
  expires_at    timestamptz,
  actor_user_id uuid references profiles on delete set null
);
create index on credit_ledger (studio_id, member_id, created_at desc);
```

Credit balance is **derived from the ledger**, never edited in place. `memberships.credits_remaining` is a cache refreshed in the same transaction as the ledger write.

```sql
create table payments (
  id                       uuid primary key default gen_random_uuid(),
  studio_id                uuid not null references studios on delete cascade,
  member_id                uuid references members on delete set null,
  membership_id            uuid references memberships on delete set null,
  booking_id               uuid references bookings on delete set null,
  amount_cents             int not null,
  currency                 char(3) not null,
  status                   payment_status not null,
  description              text,
  stripe_payment_intent_id text,
  stripe_invoice_id        text,
  stripe_charge_id         text,
  card_brand               text,
  card_last4               text,
  failure_code             text,
  failure_message          text,
  attempt_count            int not null default 0,
  next_retry_at            timestamptz,
  promo_code_id            uuid,
  gift_card_id             uuid,
  paid_at                  timestamptz
);
create unique index on payments (studio_id, stripe_payment_intent_id) where stripe_payment_intent_id is not null;
create index on payments (studio_id, status) where status in ('failed','pending');

create table refunds (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  payment_id       uuid not null references payments on delete cascade,
  amount_cents     int not null,
  reason           text not null,
  stripe_refund_id text,
  created_by       uuid references profiles on delete set null
);

create table promo_codes (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  code              text not null,
  discount_type     text not null,        -- percent | fixed
  discount_value    int not null,
  applies_to_plans  jsonb not null default '[]',   -- empty = all
  max_redemptions   int,
  redemption_count  int not null default 0,
  per_member_limit  int not null default 1,
  starts_at         timestamptz,
  ends_at           timestamptz,
  stripe_coupon_id  text,
  status            text not null default 'active',
  unique (studio_id, upper(code))
);

create table promo_redemptions (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  promo_code_id  uuid not null references promo_codes on delete cascade,
  member_id      uuid not null references members on delete cascade,
  payment_id     uuid references payments on delete set null
);

create table gift_cards (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios on delete cascade,
  code_hash            text not null,      -- never store the plaintext code
  code_last4           text not null,
  initial_amount_cents int not null,
  balance_cents        int not null,
  purchaser_member_id  uuid references members on delete set null,
  recipient_name       text,
  recipient_email      text,
  message              text,
  expires_on           date,
  status               text not null default 'active',
  unique (studio_id, code_hash)
);

create table gift_card_transactions (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  gift_card_id  uuid not null references gift_cards on delete cascade,
  delta_cents   int not null,
  payment_id    uuid references payments on delete set null,
  balance_after int not null
);
```

**Stripe note.** Because charges run on the studio's connected account, `stripe_customer_id`, `stripe_price_id` and `stripe_subscription_id` are only meaningful in the context of `studios.stripe_account_id`. Webhooks arrive on the Connect endpoint with an `account` field — always resolve tenant from that, never from payload metadata alone.

```sql
create table stripe_events (
  id                 text primary key,       -- Stripe event id, idempotency guard
  studio_id          uuid references studios on delete cascade,
  stripe_account_id  text,
  type               text not null,
  payload            jsonb not null,
  processed_at       timestamptz,
  error              text
);
```

---

## 8. Challenges & achievements

> **PATCHED for Decision 11.** Challenges are audience-typed. Participation references a profile identity, not `member_id`, so instructor challenges do not require a parallel table set.

```sql
create table challenge_templates (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid references studios on delete cascade,  -- null = system template
  title         text not null,
  description   text,
  audience      challenge_audience not null default 'member',   -- PATCH
  type          challenge_type not null,
  goal_value    int not null,
  duration_days int not null,
  reward_description text
);

create table challenges (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  template_id    uuid references challenge_templates on delete set null,
  title          text not null,
  description    text,
  cover_image_url text,
  audience       challenge_audience not null default 'member',  -- PATCH
  type           challenge_type not null,
  goal_value     int not null,
  class_type_ids jsonb not null default '[]',
  starts_on      date not null,
  ends_on        date not null,
  join_deadline  date not null,          -- mandatory, Decision 6
  auto_enrol     boolean not null default false,
  reward_description text,
  status         challenge_status not null default 'draft',
  created_by     uuid references profiles on delete set null,
  check (ends_on >= starts_on),
  check (join_deadline between starts_on and ends_on)
);

create table challenge_participants (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  challenge_id     uuid not null references challenges on delete cascade,
  audience         challenge_audience not null,                      -- PATCH
  member_id        uuid references members on delete cascade,        -- PATCH: nullable
  instructor_id    uuid references instructors on delete cascade,    -- PATCH
  joined_at        timestamptz not null default now(),
  goal_value       int not null,          -- snapshot
  progress         int not null default 0,
  last_progress_at timestamptz,
  completed_at     timestamptz,
  rank             int,
  check (
    (audience = 'member'     and member_id is not null and instructor_id is null) or
    (audience = 'instructor' and instructor_id is not null and member_id is null)
  )
);
create unique index on challenge_participants (challenge_id, member_id) where member_id is not null;
create unique index on challenge_participants (challenge_id, instructor_id) where instructor_id is not null;
create index on challenge_participants (challenge_id, progress desc, completed_at asc);

-- Progress is auditable and fully recomputable from these rows
create table challenge_progress_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  challenge_id  uuid not null references challenges on delete cascade,
  member_id     uuid references members on delete cascade,        -- PATCH: nullable
  instructor_id uuid references instructors on delete cascade,    -- PATCH
  booking_id    uuid references bookings on delete set null,
  occurrence_id uuid references class_occurrences on delete set null,  -- PATCH: instructor credit source
  delta         int not null,
  occurred_at   timestamptz not null
);
-- one credit per attendance (member) / per class taught (instructor)
create unique index on challenge_progress_events (challenge_id, member_id, booking_id)
  where member_id is not null;
create unique index on challenge_progress_events (challenge_id, instructor_id, occurrence_id)
  where instructor_id is not null;

create table achievement_definitions (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid references studios on delete cascade,  -- null = system
  code         text not null,
  name         text not null,
  description  text,
  icon         text,
  audience     challenge_audience not null default 'member',   -- PATCH
  trigger_type text not null,   -- visit_count | streak_days | challenge_completed | anniversary | first_class | classes_taught
  threshold    int,
  status       text not null default 'active'
);

create table member_achievements (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  member_id       uuid not null references members on delete cascade,
  definition_id   uuid not null references achievement_definitions on delete cascade,
  earned_at       timestamptz not null default now(),
  acknowledged_at timestamptz,
  unique (member_id, definition_id)
);

-- PATCH, Decision 10: recognition only. No rates, no accrual, no payout.
create table instructor_achievements (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  instructor_id   uuid not null references instructors on delete cascade,
  definition_id   uuid not null references achievement_definitions on delete cascade,
  earned_at       timestamptz not null default now(),
  acknowledged_at timestamptz,
  unique (instructor_id, definition_id)
);
```

**Reward redemption must be audience-aware.** An instructor cannot redeem a free class credit against a plan they do not hold. Rewards for instructor challenges are descriptive in V1 — `reward_description` text, fulfilled by the studio manually. Anything that resolves to money owed is compensation and out of scope per Decision 10.

---

## 9. AI

```sql
create table ai_insights (
  id                 uuid primary key default gen_random_uuid(),
  studio_id          uuid not null references studios on delete cascade,
  type               text not null,   -- retention_risk | milestone_upcoming | class_underfilled |
                                      -- class_overfilled | payment_failed | challenge_opportunity |
                                      -- new_member_stalled | revenue_change
  severity           text not null default 'info',
  title              text not null,
  observation        text not null,
  why_it_matters     text not null,
  recommended_action text not null,
  action_type        text not null,   -- message_member | open_class | celebrate | review_payment | launch_challenge
  action_payload     jsonb not null default '{}',
  subject_type       text,            -- member | series | occurrence | studio
  subject_id         uuid,
  estimated_impact_cents int,
  status             insight_status not null default 'new',
  for_date           date not null,
  actioned_at        timestamptz,
  actioned_by        uuid references profiles on delete set null,
  dismissed_at       timestamptz,
  model              text,
  prompt_version     text,
  input_snapshot     jsonb,           -- exactly what the model saw, for debugging
  unique (studio_id, type, subject_id, for_date)
);
create index on ai_insights (studio_id, for_date desc, status);

create table morning_briefs (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid not null references studios on delete cascade,
  brief_date   date not null,
  summary      text not null,
  metrics      jsonb not null default '{}',
  insight_ids  uuid[] not null default '{}',
  generated_at timestamptz not null default now(),
  opened_at    timestamptz,
  unique (studio_id, brief_date)
);
```

`action_type` + `action_payload` **are** the button. An insight without a valid action is a bug, not a feature.

---

## 10. Notifications

```sql
create table push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid not null references studios on delete cascade,
  member_id    uuid references members on delete cascade,
  user_id      uuid references profiles on delete cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  last_used_at timestamptz,
  revoked_at   timestamptz
);

create table notification_preferences (
  member_id            uuid primary key references members on delete cascade,
  studio_id            uuid not null references studios on delete cascade,
  booking_email        boolean not null default true,
  booking_push         boolean not null default true,
  reminder_email       boolean not null default true,
  reminder_push        boolean not null default true,
  waitlist_email       boolean not null default true,
  waitlist_push        boolean not null default true,
  milestone_push       boolean not null default true,
  challenge_push       boolean not null default true,
  marketing_email      boolean not null default false
);

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  recipient_type text not null,        -- member | staff
  member_id      uuid references members on delete cascade,
  user_id        uuid references profiles on delete cascade,
  template_key   text not null,
  channel        notif_channel not null,
  payload        jsonb not null default '{}',
  dedupe_key     text not null,
  scheduled_for  timestamptz not null,
  status         notif_status not null default 'scheduled',
  sent_at        timestamptz,
  failed_at      timestamptz,
  error          text,
  unique (dedupe_key)
);
create index on notifications (status, scheduled_for) where status = 'scheduled';
```

`dedupe_key` is deterministic — e.g. `reminder:{booking_id}` — so a retried job can never double-send.

---

## 11. Operations

```sql
create table job_runs (
  id          uuid primary key default gen_random_uuid(),
  job_key     text not null,
  run_for     date not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running',
  attempts    int not null default 1,
  error       text,
  unique (job_key, run_for)
);

create table imports (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  type        text not null,      -- members | memberships | attendance | classes
  filename    text not null,
  status      import_status not null default 'uploaded',
  mapping     jsonb not null default '{}',
  row_count   int not null default 0,
  error_count int not null default 0,
  report      jsonb not null default '{}',
  created_by  uuid references profiles on delete set null
);

create table import_rows (
  id           uuid primary key default gen_random_uuid(),
  import_id    uuid not null references imports on delete cascade,
  row_number   int not null,
  raw          jsonb not null,
  normalized   jsonb,
  status       text not null default 'pending',
  error        text,
  entity_table text,
  entity_id    uuid
);

create table audit_logs (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  actor_user_id uuid references profiles on delete set null,
  action        text not null,
  entity_table  text not null,
  entity_id     uuid,
  before        jsonb,
  after         jsonb,
  ip            inet
);
create index on audit_logs (studio_id, created_at desc);
```

`import_rows.entity_id` is what makes a rollback possible — a failed migration for a design partner must be undoable in one click.

---

## 12. Row Level Security

RLS on every tenant table, no exceptions. Three helper functions keep policies short and index-friendly:

```sql
-- studios where the current user is staff
create function auth_staff_studios() returns setof uuid
language sql stable security definer as $$
  select studio_id from studio_staff
  where user_id = auth.uid() and status = 'active'
$$;

-- studios where the current user is a member
create function auth_member_studios() returns setof uuid
language sql stable security definer as $$
  select studio_id from members
  where user_id = auth.uid() and status <> 'archived'
$$;

create function auth_role_in(target uuid) returns staff_role
language sql stable security definer as $$
  select role from studio_staff
  where user_id = auth.uid() and studio_id = target and status = 'active'
$$;
```

Policy shape per table:

| Table group | Staff | Member |
|---|---|---|
| `studios`, `studio_settings` | read all roles; write owner + manager | read own studio, public fields only (via view) |
| `members`, `member_notes`, `member_goals` | read within studio; notes with `managers_only` restricted to owner/manager; instructors read only pinned notes for members on today's roster | read/update own row only |
| `class_series`, `class_occurrences`, `rooms`, `instructors` | read all; write owner + manager | read scheduled occurrences in own studio |
| `instructor_availability` **(PATCH)** | read owner + manager + own row; write own row only, plus owner/manager | none |
| `bookings`, `check_ins` | full within studio | read/insert/cancel own only |
| `membership_plans` | read all; write owner + manager | read `visibility = 'public'` |
| `memberships`, `payments`, `credit_ledger`, `refunds` | owner + manager full; front desk read + create payment; instructor no access | read own only, no write |
| `challenges`, `challenge_participants` | read all; write owner + manager | read active; write own participation |
| `instructor_achievements` **(PATCH)** | read owner + manager + own row | none |
| `ai_insights`, `morning_briefs` | owner + manager only | none |
| `audit_logs`, `stripe_events`, `imports` | owner only | none |

Instructor access to revenue fields is denied at the policy level, not hidden in the UI.

---

## 13. Derived values & where they are computed

| Value | Source of truth | Cache |
|---|---|---|
| Class occupancy | `count(bookings where status in ('booked','attended'))` | `class_occurrences.booked_count`, same transaction |
| Credit balance | `sum(credit_ledger.delta)` | `memberships.credits_remaining`, same transaction |
| Lifetime visits | `count(check_ins)` | `members.lifetime_visits`, nightly reconcile |
| Current streak | computed from attendance dates | `members.current_streak`, nightly |
| Challenge progress | `sum(challenge_progress_events.delta)` | `challenge_participants.progress` |
| Classes taught **(PATCH)** | `count(class_occurrences where instructor_id = x and status = 'completed')` | none — computed on read |
| Retention / revenue reports | queries over `payments`, `memberships`, `check_ins` | none in V1 — no reporting tables until queries are actually slow |

Every cache is reconcilable by a nightly job. If a cache and its source disagree, the source wins and the discrepancy is logged.

---

## 14. Settled, and what remains

**Settled** (see `STUDIIOR_V1_DECISIONS.md`): several Owners per studio, minimum one, last one undeletable. One location per studio in V1, with `locations` present as a foreign key only — no UI, no multi-location logic.

Still open:

1. **Studio's own Stripe onboarding.** Connect Standard OAuth means the studio must have or create a Stripe account during setup. Worth timing with a design partner early against the one-hour target.
2. **Member identity across studios.** Same email can be a member of two studios; they sign in separately per subdomain. No policy anywhere joins them.
3. **Archived-member retention policy.** How long before a GDPR hard delete.
4. **Front-desk refund permissions.** Currently read + create payment, no refund.

---

## 15. Changes in v1.1

| Change | Source | Blocking |
|---|---|---|
| `instructor_availability` table added, with no FK from occurrences | Decision 9 | Yes — migration 001 |
| `challenge_audience` enum added | Decision 11 | Yes — migration 001 |
| `audience` column on challenges, templates, participants, achievement definitions | Decision 11 | Yes — migration 001 |
| `challenge_participants` / `challenge_progress_events` repointed to allow instructor identity | Decision 11 | Yes — migration 001 |
| `instructor_achievements` table added | Decision 10 | Yes — migration 001 |
| `join_deadline` made `not null` with range check | Decision 6 | Yes |
| Classes-taught added to derived values, no cache | Decision 10 | No |

### ⚠️ Conflict to resolve in the permissions doc

`STUDIIOR_V1_PERMISSIONS.md` §13 currently reads: *"Not in V1: availability submission, substitution requests, payroll, cross-instructor performance."*

Decision 9 supersedes the first item and Decision 10 supersedes part of the fourth. The instructor surface is now **five screens**, not three: My Schedule, Class Roster, Member Quick View, My Availability, My Stats. Substitution requests and payroll remain out. Patch that section before building the instructor app or you will build to the wrong spec.
