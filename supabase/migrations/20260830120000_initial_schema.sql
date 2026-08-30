-- =============================================================================
-- STUDIIOR — MIGRATION 001
-- Full V1 schema with Row Level Security in the same file.
--
-- Source: STUDIIOR_V1_DATA_MODEL.md v1.1, STUDIIOR_V1_PERMISSIONS.md v1.1,
--         STUDIIOR_V1_BUSINESS_RULES.md v1.1, STUDIIOR_V1_DECISIONS.md 1-11.
--
-- Rule: no table is created without its policies. A schema that exists
-- unprotected, even briefly, is a schema that ships unprotected.
-- =============================================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- =============================================================================
-- 1. ENUMS
-- =============================================================================

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
create type challenge_audience as enum ('member','instructor');   -- Decision 11
create type insight_status     as enum ('new','actioned','dismissed','expired');
create type notif_channel      as enum ('email','push','in_app');
create type notif_status       as enum ('scheduled','sent','delivered','failed','cancelled');
create type import_status      as enum ('uploaded','validating','dry_run_complete','importing','complete','failed','rolled_back');

-- =============================================================================
-- 2. updated_at TRIGGER
-- =============================================================================

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- =============================================================================
-- 3. STUDIO & IDENTITY
-- =============================================================================

create table studios (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  slug              text not null unique,
  custom_domain     text unique,
  timezone          text not null,
  currency          char(3) not null,
  country           char(2),
  logo_url          text,
  brand_color       text,
  stripe_account_id text,
  status            text not null default 'active',
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger studios_updated before update on studios
  for each row execute function set_updated_at();

-- Dormant in V1: exactly one row per studio. No UI, no multi-location logic.
create table locations (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios on delete cascade,
  name       text not null,
  address    jsonb,
  timezone   text,
  is_primary boolean not null default true,
  status     text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index locations_one_primary on locations (studio_id) where is_primary;
create index on locations (studio_id);
create trigger locations_updated before update on locations
  for each row execute function set_updated_at();

create table studio_settings (
  studio_id                 uuid primary key references studios on delete cascade,
  week_starts_on            int  not null default 1 check (week_starts_on between 0 and 6),
  booking_window_days       int  not null default 30,
  booking_cutoff_minutes    int  not null default 0,
  cancellation_cutoff_minutes int not null default 720,
  late_cancel_consumes_credit boolean not null default true,
  late_cancel_fee_cents     int  not null default 0,
  no_show_consumes_credit   boolean not null default true,
  no_show_fee_cents         int  not null default 0,
  max_bookings_per_day      int,
  max_future_bookings       int,
  waitlist_enabled          boolean not null default true,
  waitlist_offer_window_minutes int not null default 120,
  waitlist_cutoff_minutes   int  not null default 60,
  reminder_hours_before     int  not null default 12,
  payment_grace_days        int  not null default 7 check (payment_grace_days between 0 and 30),
  sub_late_free_cancel      boolean not null default true,
  require_waiver            boolean not null default true,
  waiver_text               text,
  morning_brief_send_at     time not null default '06:00',
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
create trigger studio_settings_updated before update on studio_settings
  for each row execute function set_updated_at();

-- id == auth.users.id
create table profiles (
  id         uuid primary key references auth.users on delete cascade,
  email      text not null,
  full_name  text,
  avatar_url text,
  phone      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated before update on profiles
  for each row execute function set_updated_at();

create table studio_staff (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios on delete cascade,
  user_id    uuid references profiles on delete set null,
  email      text not null,
  role       staff_role not null,
  status     text not null default 'active',
  invited_at timestamptz,
  joined_at  timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (studio_id, user_id)
);
create unique index studio_staff_email on studio_staff (studio_id, lower(email));
create index on studio_staff (user_id) where status = 'active';
create trigger studio_staff_updated before update on studio_staff
  for each row execute function set_updated_at();

-- Decision 8: at least one Owner per studio, no maximum, last one undeletable.
create or replace function guard_last_owner() returns trigger
language plpgsql as $$
declare remaining int;
begin
  if (tg_op = 'DELETE' and old.role = 'owner')
     or (tg_op = 'UPDATE' and old.role = 'owner'
         and (new.role <> 'owner' or new.status <> 'active')) then
    select count(*) into remaining
      from studio_staff
     where studio_id = old.studio_id
       and role = 'owner' and status = 'active' and id <> old.id;
    if remaining = 0 then
      raise exception 'studio % must retain at least one active owner', old.studio_id
        using errcode = 'check_violation';
    end if;
  end if;
  return coalesce(new, old);
end $$;

create trigger studio_staff_last_owner
  before update or delete on studio_staff
  for each row execute function guard_last_owner();

create table instructors (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  staff_id       uuid references studio_staff on delete set null,
  display_name   text not null,
  bio            text,
  avatar_url     text,
  color          text,
  certifications jsonb not null default '[]',
  status         text not null default 'active',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on instructors (studio_id, status);
create index on instructors (staff_id);
create trigger instructors_updated before update on instructors
  for each row execute function set_updated_at();

create table rooms (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  location_id uuid not null references locations on delete cascade,
  name        text not null,
  capacity    int not null check (capacity > 0),
  color       text,
  status      text not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on rooms (studio_id);
create trigger rooms_updated before update on rooms
  for each row execute function set_updated_at();

-- =============================================================================
-- 4. RLS HELPER FUNCTIONS
--    Defined after studio_staff / members so they can reference them.
--    security definer + fixed search_path: these run above RLS deliberately.
-- =============================================================================

create table members (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  user_id           uuid references profiles on delete set null,
  first_name        text not null,
  last_name         text not null,
  email             text not null,
  phone             text,
  date_of_birth     date,
  avatar_url        text,
  address           jsonb,
  emergency_contact jsonb,
  status            member_status not null default 'active',
  joined_on         date not null default current_date,
  source            text,
  marketing_opt_in  boolean not null default false,
  waiver_signed_at  timestamptz,
  first_visit_at    timestamptz,
  last_visit_at     timestamptz,
  lifetime_visits   int not null default 0,
  current_streak    int not null default 0,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index members_email on members (studio_id, lower(email));
create index on members (studio_id, status);
create index on members (user_id) where user_id is not null;
create trigger members_updated before update on members
  for each row execute function set_updated_at();

create function auth_staff_studios() returns setof uuid
language sql stable security definer set search_path = public as $$
  select studio_id from studio_staff
  where user_id = auth.uid() and status = 'active'
$$;

create function auth_member_studios() returns setof uuid
language sql stable security definer set search_path = public as $$
  select studio_id from members
  where user_id = auth.uid() and status <> 'archived'
$$;

create function auth_role_in(target uuid) returns staff_role
language sql stable security definer set search_path = public as $$
  select role from studio_staff
  where user_id = auth.uid() and studio_id = target and status = 'active'
$$;

-- Convenience predicates, used heavily below.
create function is_manager_up(target uuid) returns boolean
language sql stable as $$
  select auth_role_in(target) in ('owner','manager')
$$;

create function is_desk_up(target uuid) returns boolean
language sql stable as $$
  select auth_role_in(target) in ('owner','manager','front_desk')
$$;

create function is_owner(target uuid) returns boolean
language sql stable as $$
  select auth_role_in(target) = 'owner'
$$;

-- The instructor record belonging to the current user in a given studio.
create function auth_instructor_id(target uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select i.id from instructors i
  join studio_staff s on s.id = i.staff_id
  where s.user_id = auth.uid() and s.status = 'active' and i.studio_id = target
  limit 1
$$;

-- =============================================================================
-- 5. MEMBER CRM
-- =============================================================================

create table member_tags (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios on delete cascade,
  name       text not null,
  color      text,
  created_at timestamptz not null default now()
);
create unique index member_tags_name on member_tags (studio_id, lower(name));

create table member_tag_assignments (
  member_id  uuid not null references members on delete cascade,
  tag_id     uuid not null references member_tags on delete cascade,
  studio_id  uuid not null references studios on delete cascade,
  created_at timestamptz not null default now(),
  primary key (member_id, tag_id)
);
create index on member_tag_assignments (studio_id, tag_id);

create table member_notes (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  member_id      uuid not null references members on delete cascade,
  author_user_id uuid references profiles on delete set null,
  category       note_category not null default 'general',
  body           text not null,
  active         boolean not null default true,
  pinned         boolean not null default false,
  managers_only  boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on member_notes (studio_id, member_id) where active;
create trigger member_notes_updated before update on member_notes
  for each row execute function set_updated_at();

create table member_goals (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  title         text not null,
  target_type   text not null,
  target_value  int,
  current_value int not null default 0,
  target_date   date,
  completed_at  timestamptz,
  status        text not null default 'active',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on member_goals (studio_id, member_id);
create trigger member_goals_updated before update on member_goals
  for each row execute function set_updated_at();

create table timeline_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  type          text not null,
  occurred_at   timestamptz not null,
  title         text not null,
  description   text,
  actor_user_id uuid references profiles on delete set null,
  ref_table     text,
  ref_id        uuid,
  metadata      jsonb not null default '{}',
  created_at    timestamptz not null default now()
);
create index on timeline_events (studio_id, member_id, occurred_at desc);

-- =============================================================================
-- 6. SCHEDULING
-- =============================================================================

create table class_types (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  name             text not null,
  description      text,
  duration_minutes int not null,
  default_capacity int not null,
  difficulty       text,
  color            text,
  status           text not null default 'active',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on class_types (studio_id, status);
create trigger class_types_updated before update on class_types
  for each row execute function set_updated_at();

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
  rrule               text not null,
  starts_on           date not null,
  ends_on             date,
  time_of_day         time not null,
  booking_window_days int,
  status              series_status not null default 'active',
  created_by          uuid references profiles on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index on class_series (studio_id, status);
create trigger class_series_updated before update on class_series
  for each row execute function set_updated_at();

create table class_occurrences (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios on delete cascade,
  location_id         uuid not null references locations on delete cascade,
  series_id           uuid references class_series on delete cascade,
  class_type_id       uuid references class_types on delete set null,
  name                text not null,
  description         text,
  instructor_id       uuid references instructors on delete set null,
  substitute_for      uuid references instructors on delete set null,
  room_id             uuid references rooms on delete set null,
  capacity            int not null check (capacity > 0),
  starts_at           timestamptz not null,
  ends_at             timestamptz not null,
  status              occurrence_status not null default 'scheduled',
  is_exception        boolean not null default false,
  booked_count        int not null default 0,
  waitlist_count      int not null default 0,
  cancelled_at        timestamptz,
  cancellation_reason text,
  instructor_notes    text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (ends_at > starts_at)
);
create unique index on class_occurrences (series_id, starts_at) where series_id is not null;
create index on class_occurrences (studio_id, starts_at);
create index on class_occurrences (studio_id, instructor_id, starts_at);
create trigger class_occurrences_updated before update on class_occurrences
  for each row execute function set_updated_at();

-- Decision 9. No FK from occurrences to this table, deliberately.
create table instructor_availability (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  instructor_id  uuid not null references instructors on delete cascade,
  day_of_week    int check (day_of_week between 0 and 6),
  starts_at_time time,
  ends_at_time   time,
  effective_from date,
  effective_to   date,
  exception_date date,
  is_available   boolean not null default true,
  note           text,
  created_by     uuid references profiles on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check ((day_of_week is not null) <> (exception_date is not null)),
  check (ends_at_time is null or starts_at_time is null or ends_at_time > starts_at_time)
);
create index on instructor_availability (studio_id, instructor_id, day_of_week);
create index on instructor_availability (studio_id, exception_date) where exception_date is not null;
create trigger instructor_availability_updated before update on instructor_availability
  for each row execute function set_updated_at();

-- =============================================================================
-- 7. MEMBERSHIPS, PACKS & PAYMENTS
-- =============================================================================

create table membership_plans (
  id                       uuid primary key default gen_random_uuid(),
  studio_id                uuid not null references studios on delete cascade,
  name                     text not null,
  description              text,
  type                     plan_type not null,
  price_cents              int not null check (price_cents >= 0),
  currency                 char(3) not null,
  billing_interval         billing_interval,
  billing_interval_count   int not null default 1,
  credits                  int,
  credits_per_period       int,
  validity_days            int,
  signup_fee_cents         int not null default 0,
  commitment_months        int not null default 0,
  cancellation_notice_days int not null default 0,
  freeze_allowed           boolean not null default true,
  max_freeze_days          int,
  booking_window_days      int,
  max_bookings_per_day     int,
  restrictions             jsonb not null default '{}',
  stripe_product_id        text,
  stripe_price_id          text,
  visibility               text not null default 'public',
  status                   text not null default 'active',
  sort_order               int not null default 0,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index on membership_plans (studio_id, status);
create trigger membership_plans_updated before update on membership_plans
  for each row execute function set_updated_at();

create table memberships (
  id                     uuid primary key default gen_random_uuid(),
  studio_id              uuid not null references studios on delete cascade,
  member_id              uuid not null references members on delete cascade,
  plan_id                uuid not null references membership_plans,
  status                 membership_status not null,
  price_cents            int not null,
  currency               char(3) not null,
  starts_on              date not null,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  renews_on              date,
  expires_on             date,
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
  stripe_subscription_id text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index on memberships (studio_id, status);
create index on memberships (studio_id, member_id);
create index on memberships (studio_id, renews_on) where status = 'active';
create trigger memberships_updated before update on memberships
  for each row execute function set_updated_at();

create table membership_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  membership_id uuid not null references memberships on delete cascade,
  type          text not null,
  from_status   membership_status,
  to_status     membership_status,
  effective_at  timestamptz not null default now(),
  actor_user_id uuid references profiles on delete set null,
  metadata      jsonb not null default '{}',
  created_at    timestamptz not null default now()
);
create index on membership_events (studio_id, membership_id, effective_at desc);

-- =============================================================================
-- 8. BOOKINGS, WAITLIST, CHECK-IN
-- =============================================================================

create table bookings (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  occurrence_id     uuid not null references class_occurrences on delete cascade,
  member_id         uuid not null references members on delete cascade,
  status            booking_status not null default 'booked',
  source            booking_source not null default 'member',
  payment_source    payment_source,
  membership_id     uuid references memberships on delete set null,
  credit_entry_id   uuid,
  waitlist_position int,
  booked_at         timestamptz not null default now(),
  cancelled_at      timestamptz,
  cancelled_by      uuid references profiles on delete set null,
  is_late_cancel    boolean not null default false,
  fee_charged_cents int not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index bookings_one_live_per_member
  on bookings (occurrence_id, member_id)
  where status in ('booked','waitlisted','attended','no_show');
create index on bookings (studio_id, member_id, booked_at desc);
create index on bookings (occurrence_id, status, waitlist_position);
create trigger bookings_updated before update on bookings
  for each row execute function set_updated_at();

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
  actor_user_id uuid references profiles on delete set null,
  created_at    timestamptz not null default now()
);
create index on credit_ledger (studio_id, member_id, created_at desc);
create index on credit_ledger (studio_id, expires_at) where expires_at is not null;

create table waitlist_offers (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  booking_id    uuid not null references bookings on delete cascade,
  occurrence_id uuid not null references class_occurrences on delete cascade,
  offered_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  responded_at  timestamptz,
  outcome       text,
  created_at    timestamptz not null default now()
);
create index on waitlist_offers (expires_at) where outcome is null;
create index on waitlist_offers (studio_id, occurrence_id);

create table check_ins (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  booking_id    uuid not null unique references bookings on delete cascade,
  member_id     uuid not null references members on delete cascade,
  occurrence_id uuid not null references class_occurrences on delete cascade,
  checked_in_at timestamptz not null default now(),
  method        checkin_method not null,
  checked_in_by uuid references profiles on delete set null,
  created_at    timestamptz not null default now()
);
create index on check_ins (studio_id, member_id, checked_in_at desc);
create index on check_ins (studio_id, occurrence_id);

-- =============================================================================
-- 9. PAYMENTS
-- =============================================================================

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
  paid_at                  timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create unique index on payments (studio_id, stripe_payment_intent_id)
  where stripe_payment_intent_id is not null;
create index on payments (studio_id, status) where status in ('failed','pending');
create index on payments (studio_id, member_id, created_at desc);
create trigger payments_updated before update on payments
  for each row execute function set_updated_at();

create table refunds (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  payment_id       uuid not null references payments on delete cascade,
  amount_cents     int not null,
  reason           text not null,
  stripe_refund_id text,
  created_by       uuid references profiles on delete set null,
  created_at       timestamptz not null default now()
);
create index on refunds (studio_id, payment_id);

create table promo_codes (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  code             text not null,
  discount_type    text not null,
  discount_value   int not null,
  applies_to_plans jsonb not null default '[]',
  max_redemptions  int,
  redemption_count int not null default 0,
  per_member_limit int not null default 1,
  starts_at        timestamptz,
  ends_at          timestamptz,
  stripe_coupon_id text,
  status           text not null default 'active',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index promo_codes_code on promo_codes (studio_id, upper(code));
create trigger promo_codes_updated before update on promo_codes
  for each row execute function set_updated_at();

create table promo_redemptions (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  promo_code_id uuid not null references promo_codes on delete cascade,
  member_id     uuid not null references members on delete cascade,
  payment_id    uuid references payments on delete set null,
  created_at    timestamptz not null default now()
);
create index on promo_redemptions (studio_id, promo_code_id, member_id);

create table gift_cards (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios on delete cascade,
  code_hash            text not null,
  code_last4           text not null,
  initial_amount_cents int not null,
  balance_cents        int not null,
  purchaser_member_id  uuid references members on delete set null,
  recipient_name       text,
  recipient_email      text,
  message              text,
  expires_on           date,
  status               text not null default 'active',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (studio_id, code_hash)
);
create trigger gift_cards_updated before update on gift_cards
  for each row execute function set_updated_at();

create table gift_card_transactions (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  gift_card_id  uuid not null references gift_cards on delete cascade,
  delta_cents   int not null,
  payment_id    uuid references payments on delete set null,
  balance_after int not null,
  created_at    timestamptz not null default now()
);
create index on gift_card_transactions (studio_id, gift_card_id);

alter table payments add constraint payments_promo_fk
  foreign key (promo_code_id) references promo_codes on delete set null;
alter table payments add constraint payments_gift_card_fk
  foreign key (gift_card_id) references gift_cards on delete set null;

create table stripe_events (
  id                text primary key,
  studio_id         uuid references studios on delete cascade,
  stripe_account_id text,
  type              text not null,
  payload           jsonb not null,
  processed_at      timestamptz,
  error             text,
  created_at        timestamptz not null default now()
);
create index on stripe_events (studio_id, type);

-- =============================================================================
-- 10. CHALLENGES & ACHIEVEMENTS  (Decisions 6, 10, 11)
-- =============================================================================

create table challenge_templates (
  id                 uuid primary key default gen_random_uuid(),
  studio_id          uuid references studios on delete cascade,   -- null = system
  title              text not null,
  description        text,
  audience           challenge_audience not null default 'member',
  type               challenge_type not null,
  goal_value         int not null,
  duration_days      int not null,
  reward_description text,
  created_at         timestamptz not null default now()
);
create index on challenge_templates (studio_id, audience);

create table challenges (
  id                 uuid primary key default gen_random_uuid(),
  studio_id          uuid not null references studios on delete cascade,
  template_id        uuid references challenge_templates on delete set null,
  title              text not null,
  description        text,
  cover_image_url    text,
  audience           challenge_audience not null default 'member',
  type               challenge_type not null,
  goal_value         int not null check (goal_value > 0),
  class_type_ids     jsonb not null default '[]',
  starts_on          date not null,
  ends_on            date not null,
  join_deadline      date not null,                       -- Decision 6: mandatory
  auto_enrol         boolean not null default false,
  reward_description text,
  status             challenge_status not null default 'draft',
  created_by         uuid references profiles on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (join_deadline between starts_on and ends_on)
);
create index on challenges (studio_id, status, audience);
create trigger challenges_updated before update on challenges
  for each row execute function set_updated_at();

create table challenge_participants (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  challenge_id     uuid not null references challenges on delete cascade,
  audience         challenge_audience not null,
  member_id        uuid references members on delete cascade,
  instructor_id    uuid references instructors on delete cascade,
  joined_at        timestamptz not null default now(),
  goal_value       int not null,
  progress         int not null default 0,
  last_progress_at timestamptz,
  completed_at     timestamptz,
  rank             int,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (
    (audience = 'member'     and member_id is not null and instructor_id is null) or
    (audience = 'instructor' and instructor_id is not null and member_id is null)
  )
);
create unique index challenge_participants_member
  on challenge_participants (challenge_id, member_id) where member_id is not null;
create unique index challenge_participants_instructor
  on challenge_participants (challenge_id, instructor_id) where instructor_id is not null;
create index on challenge_participants (challenge_id, progress desc, completed_at asc);
create trigger challenge_participants_updated before update on challenge_participants
  for each row execute function set_updated_at();

create table challenge_progress_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  challenge_id  uuid not null references challenges on delete cascade,
  member_id     uuid references members on delete cascade,
  instructor_id uuid references instructors on delete cascade,
  booking_id    uuid references bookings on delete set null,
  occurrence_id uuid references class_occurrences on delete set null,
  delta         int not null,
  occurred_at   timestamptz not null,
  created_at    timestamptz not null default now(),
  check ((member_id is not null) <> (instructor_id is not null))
);
create unique index challenge_progress_member
  on challenge_progress_events (challenge_id, member_id, booking_id)
  where member_id is not null;
create unique index challenge_progress_instructor
  on challenge_progress_events (challenge_id, instructor_id, occurrence_id)
  where instructor_id is not null;

create table achievement_definitions (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid references studios on delete cascade,   -- null = system
  code         text not null,
  name         text not null,
  description  text,
  icon         text,
  audience     challenge_audience not null default 'member',
  trigger_type text not null,
  threshold    int,
  status       text not null default 'active',
  created_at   timestamptz not null default now()
);
create unique index achievement_definitions_code
  on achievement_definitions (coalesce(studio_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

create table member_achievements (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  member_id       uuid not null references members on delete cascade,
  definition_id   uuid not null references achievement_definitions on delete cascade,
  earned_at       timestamptz not null default now(),
  acknowledged_at timestamptz,
  created_at      timestamptz not null default now(),
  unique (member_id, definition_id)
);
create index on member_achievements (studio_id, member_id);

-- Decision 10: recognition only. No rates, no accrual, no payout.
create table instructor_achievements (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  instructor_id   uuid not null references instructors on delete cascade,
  definition_id   uuid not null references achievement_definitions on delete cascade,
  earned_at       timestamptz not null default now(),
  acknowledged_at timestamptz,
  created_at      timestamptz not null default now(),
  unique (instructor_id, definition_id)
);
create index on instructor_achievements (studio_id, instructor_id);

-- =============================================================================
-- 11. AI
-- =============================================================================

create table ai_insights (
  id                     uuid primary key default gen_random_uuid(),
  studio_id              uuid not null references studios on delete cascade,
  type                   text not null,
  severity               text not null default 'info',
  title                  text not null,
  observation            text not null,
  why_it_matters         text not null,
  recommended_action     text not null,
  action_type            text not null,
  action_payload         jsonb not null default '{}',
  subject_type           text,
  subject_id             uuid,
  estimated_impact_cents int,
  status                 insight_status not null default 'new',
  for_date               date not null,
  actioned_at            timestamptz,
  actioned_by            uuid references profiles on delete set null,
  dismissed_at           timestamptz,
  model                  text,
  prompt_version         text,
  input_snapshot         jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (studio_id, type, subject_id, for_date)
);
create index on ai_insights (studio_id, for_date desc, status);
create trigger ai_insights_updated before update on ai_insights
  for each row execute function set_updated_at();

create table morning_briefs (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid not null references studios on delete cascade,
  brief_date   date not null,
  summary      text not null,
  metrics      jsonb not null default '{}',
  insight_ids  uuid[] not null default '{}',
  generated_at timestamptz not null default now(),
  opened_at    timestamptz,
  created_at   timestamptz not null default now(),
  unique (studio_id, brief_date)
);

-- =============================================================================
-- 12. NOTIFICATIONS
-- =============================================================================

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
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index on push_subscriptions (studio_id, member_id) where revoked_at is null;

create table notification_preferences (
  member_id       uuid primary key references members on delete cascade,
  studio_id       uuid not null references studios on delete cascade,
  booking_email   boolean not null default true,
  booking_push    boolean not null default true,
  reminder_email  boolean not null default true,
  reminder_push   boolean not null default true,
  waitlist_email  boolean not null default true,
  waitlist_push   boolean not null default true,
  milestone_push  boolean not null default true,
  challenge_push  boolean not null default true,
  marketing_email boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger notification_preferences_updated before update on notification_preferences
  for each row execute function set_updated_at();

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  recipient_type text not null,
  member_id      uuid references members on delete cascade,
  user_id        uuid references profiles on delete cascade,
  template_key   text not null,
  channel        notif_channel not null,
  payload        jsonb not null default '{}',
  dedupe_key     text not null unique,
  scheduled_for  timestamptz not null,
  status         notif_status not null default 'scheduled',
  sent_at        timestamptz,
  failed_at      timestamptz,
  error          text,
  created_at     timestamptz not null default now()
);
create index on notifications (status, scheduled_for) where status = 'scheduled';

-- =============================================================================
-- 13. OPERATIONS
-- =============================================================================

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
  type        text not null,
  filename    text not null,
  status      import_status not null default 'uploaded',
  mapping     jsonb not null default '{}',
  row_count   int not null default 0,
  error_count int not null default 0,
  report      jsonb not null default '{}',
  created_by  uuid references profiles on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger imports_updated before update on imports
  for each row execute function set_updated_at();

create table import_rows (
  id           uuid primary key default gen_random_uuid(),
  import_id    uuid not null references imports on delete cascade,
  row_number   int not null,
  raw          jsonb not null,
  normalized   jsonb,
  status       text not null default 'pending',
  error        text,
  entity_table text,
  entity_id    uuid,
  created_at   timestamptz not null default now()
);
create index on import_rows (import_id, status);

create table audit_logs (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  actor_user_id uuid references profiles on delete set null,
  action        text not null,
  entity_table  text not null,
  entity_id     uuid,
  before        jsonb,
  after         jsonb,
  ip            inet,
  created_at    timestamptz not null default now()
);
create index on audit_logs (studio_id, created_at desc);

-- =============================================================================
-- 14. ROW LEVEL SECURITY
--
-- Enabled on every tenant table. Postgres denies by default once enabled,
-- so any table without a policy below is closed to everyone but the
-- service role, which bypasses RLS.
-- =============================================================================

alter table studios                   enable row level security;
alter table locations                 enable row level security;
alter table studio_settings           enable row level security;
alter table profiles                  enable row level security;
alter table studio_staff              enable row level security;
alter table instructors               enable row level security;
alter table instructor_availability   enable row level security;
alter table rooms                     enable row level security;
alter table members                   enable row level security;
alter table member_tags               enable row level security;
alter table member_tag_assignments    enable row level security;
alter table member_notes              enable row level security;
alter table member_goals              enable row level security;
alter table timeline_events           enable row level security;
alter table class_types               enable row level security;
alter table class_series              enable row level security;
alter table class_occurrences         enable row level security;
alter table membership_plans          enable row level security;
alter table memberships               enable row level security;
alter table membership_events         enable row level security;
alter table bookings                  enable row level security;
alter table credit_ledger             enable row level security;
alter table waitlist_offers           enable row level security;
alter table check_ins                 enable row level security;
alter table payments                  enable row level security;
alter table refunds                   enable row level security;
alter table promo_codes               enable row level security;
alter table promo_redemptions         enable row level security;
alter table gift_cards                enable row level security;
alter table gift_card_transactions    enable row level security;
alter table stripe_events             enable row level security;
alter table challenge_templates       enable row level security;
alter table challenges                enable row level security;
alter table challenge_participants    enable row level security;
alter table challenge_progress_events enable row level security;
alter table achievement_definitions   enable row level security;
alter table member_achievements       enable row level security;
alter table instructor_achievements   enable row level security;
alter table ai_insights               enable row level security;
alter table morning_briefs            enable row level security;
alter table push_subscriptions        enable row level security;
alter table notification_preferences  enable row level security;
alter table notifications             enable row level security;
alter table imports                   enable row level security;
alter table import_rows               enable row level security;
alter table audit_logs                enable row level security;
alter table job_runs                  enable row level security;

-- --- Studio & config -------------------------------------------------------

create policy studios_staff_read on studios for select
  using (id in (select auth_staff_studios()));
create policy studios_member_read on studios for select
  using (id in (select auth_member_studios()));
create policy studios_owner_write on studios for update
  using (is_owner(id)) with check (is_owner(id));

create policy locations_staff_read on locations for select
  using (studio_id in (select auth_staff_studios()));
create policy locations_member_read on locations for select
  using (studio_id in (select auth_member_studios()));
create policy locations_manager_write on locations for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy settings_staff_read on studio_settings for select
  using (studio_id in (select auth_staff_studios()));
create policy settings_manager_write on studio_settings for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy profiles_self on profiles for all
  using (id = auth.uid()) with check (id = auth.uid());

create policy staff_read on studio_staff for select
  using (studio_id in (select auth_staff_studios()));
-- Managers may write Instructor and Front Desk rows only; Owners write anything.
create policy staff_write on studio_staff for all
  using (
    is_owner(studio_id)
    or (auth_role_in(studio_id) = 'manager' and role in ('instructor','front_desk'))
  )
  with check (
    is_owner(studio_id)
    or (auth_role_in(studio_id) = 'manager' and role in ('instructor','front_desk'))
  );

create policy instructors_staff_read on instructors for select
  using (studio_id in (select auth_staff_studios()));
create policy instructors_member_read on instructors for select
  using (studio_id in (select auth_member_studios()));
create policy instructors_manager_write on instructors for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy instructors_self_update on instructors for update
  using (id = auth_instructor_id(studio_id))
  with check (id = auth_instructor_id(studio_id));

-- Decision 9: instructors write only their own availability.
create policy availability_manager_all on instructor_availability for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy availability_self on instructor_availability for all
  using (instructor_id = auth_instructor_id(studio_id))
  with check (instructor_id = auth_instructor_id(studio_id));

create policy rooms_staff_read on rooms for select
  using (studio_id in (select auth_staff_studios()));
create policy rooms_manager_write on rooms for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

-- --- Members & CRM ---------------------------------------------------------

create policy members_staff_read on members for select
  using (studio_id in (select auth_staff_studios()));
create policy members_desk_write on members for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));
create policy members_self on members for select
  using (user_id = auth.uid());
create policy members_self_update on members for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy tags_staff_read on member_tags for select
  using (studio_id in (select auth_staff_studios()));
create policy tags_desk_write on member_tags for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

create policy tag_assign_staff_read on member_tag_assignments for select
  using (studio_id in (select auth_staff_studios()));
create policy tag_assign_desk_write on member_tag_assignments for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

-- managers_only notes are denied to Instructor and Front Desk.
create policy notes_read on member_notes for select
  using (
    studio_id in (select auth_staff_studios())
    and (is_manager_up(studio_id) or not managers_only)
  );
create policy notes_write on member_notes for all
  using (
    studio_id in (select auth_staff_studios())
    and (is_manager_up(studio_id) or not managers_only)
  )
  with check (
    studio_id in (select auth_staff_studios())
    and (is_manager_up(studio_id) or not managers_only)
  );

create policy goals_staff_read on member_goals for select
  using (studio_id in (select auth_staff_studios()));
create policy goals_manager_write on member_goals for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy goals_self on member_goals for all
  using (member_id in (select id from members where user_id = auth.uid()))
  with check (member_id in (select id from members where user_id = auth.uid()));

create policy timeline_staff_read on timeline_events for select
  using (studio_id in (select auth_staff_studios()));
create policy timeline_self on timeline_events for select
  using (member_id in (select id from members where user_id = auth.uid()));

-- --- Scheduling ------------------------------------------------------------

create policy class_types_staff_read on class_types for select
  using (studio_id in (select auth_staff_studios()));
create policy class_types_member_read on class_types for select
  using (studio_id in (select auth_member_studios()));
create policy class_types_manager_write on class_types for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy series_staff_read on class_series for select
  using (studio_id in (select auth_staff_studios()));
create policy series_manager_write on class_series for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy occ_staff_read on class_occurrences for select
  using (studio_id in (select auth_staff_studios()));
create policy occ_member_read on class_occurrences for select
  using (studio_id in (select auth_member_studios()) and status = 'scheduled');
create policy occ_manager_write on class_occurrences for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
-- Front desk adjusts booked_count via the booking function, and may override
-- capacity for a walk-in. Instructors write notes on their own classes only.
create policy occ_desk_update on class_occurrences for update
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));
create policy occ_instructor_update on class_occurrences for update
  using (instructor_id = auth_instructor_id(studio_id))
  with check (instructor_id = auth_instructor_id(studio_id));

-- --- Memberships & money ---------------------------------------------------

create policy plans_staff_read on membership_plans for select
  using (studio_id in (select auth_staff_studios()) and auth_role_in(studio_id) <> 'instructor');
create policy plans_member_read on membership_plans for select
  using (studio_id in (select auth_member_studios()) and visibility = 'public');
create policy plans_manager_write on membership_plans for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy memberships_staff_read on memberships for select
  using (is_desk_up(studio_id));
create policy memberships_manager_write on memberships for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy memberships_desk_insert on memberships for insert
  with check (is_desk_up(studio_id));
create policy memberships_self on memberships for select
  using (member_id in (select id from members where user_id = auth.uid()));

create policy membership_events_read on membership_events for select
  using (is_manager_up(studio_id));
create policy membership_events_write on membership_events for insert
  with check (is_desk_up(studio_id));

create policy credit_staff_read on credit_ledger for select
  using (is_desk_up(studio_id));
create policy credit_manager_write on credit_ledger for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy credit_self on credit_ledger for select
  using (member_id in (select id from members where user_id = auth.uid()));

create policy payments_manager_read on payments for select
  using (is_manager_up(studio_id));
create policy payments_desk_read on payments for select
  using (auth_role_in(studio_id) = 'front_desk');
create policy payments_desk_insert on payments for insert
  with check (is_desk_up(studio_id));
create policy payments_manager_write on payments for update
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy payments_self on payments for select
  using (member_id in (select id from members where user_id = auth.uid()));

create policy refunds_manager on refunds for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy promo_manager on promo_codes for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy promo_desk_read on promo_codes for select
  using (is_desk_up(studio_id));

create policy promo_red_staff on promo_redemptions for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

create policy gift_staff on gift_cards for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));
create policy gift_tx_staff on gift_card_transactions for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

create policy stripe_events_owner on stripe_events for select
  using (studio_id is not null and is_owner(studio_id));

-- --- Bookings & attendance -------------------------------------------------

create policy bookings_staff_read on bookings for select
  using (studio_id in (select auth_staff_studios()));
create policy bookings_desk_write on bookings for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));
create policy bookings_self_read on bookings for select
  using (member_id in (select id from members where user_id = auth.uid()));
create policy bookings_self_insert on bookings for insert
  with check (member_id in (select id from members where user_id = auth.uid()));
create policy bookings_self_update on bookings for update
  using (member_id in (select id from members where user_id = auth.uid()))
  with check (member_id in (select id from members where user_id = auth.uid()));

create policy waitlist_staff on waitlist_offers for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));
create policy waitlist_staff_read on waitlist_offers for select
  using (studio_id in (select auth_staff_studios()));
create policy waitlist_self on waitlist_offers for select
  using (booking_id in (
    select b.id from bookings b join members m on m.id = b.member_id
    where m.user_id = auth.uid()
  ));

create policy checkins_staff on check_ins for all
  using (studio_id in (select auth_staff_studios()))
  with check (studio_id in (select auth_staff_studios()));
create policy checkins_self_read on check_ins for select
  using (member_id in (select id from members where user_id = auth.uid()));

-- --- Challenges ------------------------------------------------------------

create policy ch_templates_staff on challenge_templates for select
  using (studio_id is null or studio_id in (select auth_staff_studios()));
create policy ch_templates_manager on challenge_templates for all
  using (studio_id is not null and is_manager_up(studio_id))
  with check (studio_id is not null and is_manager_up(studio_id));

create policy challenges_staff_read on challenges for select
  using (studio_id in (select auth_staff_studios()));
create policy challenges_member_read on challenges for select
  using (studio_id in (select auth_member_studios())
         and audience = 'member'
         and status in ('scheduled','active','ended'));
create policy challenges_manager_write on challenges for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy cp_staff_read on challenge_participants for select
  using (studio_id in (select auth_staff_studios()));
create policy cp_manager_write on challenge_participants for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy cp_desk_enrol on challenge_participants for insert
  with check (is_desk_up(studio_id));
create policy cp_member_self on challenge_participants for all
  using (member_id in (select id from members where user_id = auth.uid()))
  with check (member_id in (select id from members where user_id = auth.uid()));
create policy cp_instructor_self on challenge_participants for all
  using (instructor_id = auth_instructor_id(studio_id))
  with check (instructor_id = auth_instructor_id(studio_id));
-- Leaderboard visibility: participants see co-participants in their own challenge.
create policy cp_leaderboard on challenge_participants for select
  using (challenge_id in (
    select cp.challenge_id from challenge_participants cp
    join members m on m.id = cp.member_id
    where m.user_id = auth.uid()
  ));

create policy cpe_staff_read on challenge_progress_events for select
  using (studio_id in (select auth_staff_studios()));
create policy cpe_manager_write on challenge_progress_events for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy cpe_self on challenge_progress_events for select
  using (member_id in (select id from members where user_id = auth.uid()));

create policy ach_def_read on achievement_definitions for select
  using (studio_id is null or studio_id in (select auth_staff_studios())
         or studio_id in (select auth_member_studios()));
create policy ach_def_manager on achievement_definitions for all
  using (studio_id is not null and is_manager_up(studio_id))
  with check (studio_id is not null and is_manager_up(studio_id));

create policy member_ach_staff on member_achievements for select
  using (studio_id in (select auth_staff_studios()));
create policy member_ach_manager on member_achievements for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy member_ach_self on member_achievements for select
  using (member_id in (select id from members where user_id = auth.uid()));

create policy instructor_ach_manager on instructor_achievements for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy instructor_ach_self on instructor_achievements for select
  using (instructor_id = auth_instructor_id(studio_id));

-- --- AI --------------------------------------------------------------------

create policy insights_manager on ai_insights for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy briefs_manager on morning_briefs for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

-- --- Notifications ---------------------------------------------------------

create policy push_self on push_subscriptions for all
  using (user_id = auth.uid()
         or member_id in (select id from members where user_id = auth.uid()))
  with check (user_id = auth.uid()
         or member_id in (select id from members where user_id = auth.uid()));

create policy notif_prefs_self on notification_preferences for all
  using (member_id in (select id from members where user_id = auth.uid()))
  with check (member_id in (select id from members where user_id = auth.uid()));
create policy notif_prefs_staff on notification_preferences for select
  using (is_desk_up(studio_id));

create policy notifications_manager on notifications for select
  using (is_manager_up(studio_id));
create policy notifications_self on notifications for select
  using (user_id = auth.uid()
         or member_id in (select id from members where user_id = auth.uid()));

-- --- Operations ------------------------------------------------------------

create policy imports_manager on imports for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy import_rows_manager on import_rows for all
  using (import_id in (select id from imports where is_manager_up(studio_id)))
  with check (import_id in (select id from imports where is_manager_up(studio_id)));

create policy audit_owner_read on audit_logs for select
  using (is_owner(studio_id));
create policy audit_staff_insert on audit_logs for insert
  with check (studio_id in (select auth_staff_studios()));

-- job_runs has no policy: service role only.

-- =============================================================================
-- 15. RESTRICTED VIEWS
--
-- Field-level denials from Permissions §14. Instructors read members through
-- this view, never the base table. security_invoker so RLS still applies.
-- =============================================================================

create view member_quick_view
  with (security_invoker = true) as
select
  m.id, m.studio_id, m.first_name, m.last_name, m.avatar_url,
  m.date_of_birth, m.status, m.joined_on,
  m.first_visit_at, m.last_visit_at, m.lifetime_visits, m.current_streak
from members m;

comment on view member_quick_view is
  'Instructor-safe member projection. No email, phone, address, emergency contact.';

create view studio_public
  with (security_invoker = true) as
select id, name, slug, custom_domain, timezone, currency,
       country, logo_url, brand_color, status
from studios;

comment on view studio_public is
  'Studio without stripe_account_id. Owner-only field per Permissions §14.';

-- =============================================================================
-- END MIGRATION 001
-- =============================================================================
