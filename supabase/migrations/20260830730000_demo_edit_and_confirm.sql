-- =============================================================================
-- Migration 063: a record you have edited is yours, and a purge asks first
-- =============================================================================
-- Two holes left by 062.
--
-- 1. Editing a demo record into a real one kept is_demo, so it stayed
--    silently purgeable. That is the likeliest explanation for the three
--    instructors production lost that no cascade accounts for: demo rows typed
--    over with real people's names, still carrying the flag.
--
-- 2. purge_demo_data() had no confirmation step and no caller in the app — it
--    is run by an operator in a SQL console, which is exactly the situation
--    where nothing makes you stop and read. archive_record() already refuses
--    until confirmed and returns what will happen; this does the same, and the
--    census 062 added is the right thing to show.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. A human edit promotes the row out of the demo set
-- -----------------------------------------------------------------------------
-- CLEARING THE FLAG rather than refusing the edit, deliberately. Using the demo
-- data as a starting point is a real onboarding path — a studio opens the demo
-- instructor, types their own person's name over it and saves. Refusing at that
-- moment throws away what they just typed and teaches them the demo is a trap.
-- Promoting keeps the work and makes the record theirs, which is the outcome
-- both options are trying to reach.
--
-- WHAT COUNTS AS AN EDIT is the whole difficulty. Machine-maintained columns
-- must not promote anything, or a demo member becomes real the moment the
-- nightly health job runs and the demo can never be cleaned up again. So the
-- comparison ignores a per-table list of system columns and looks at everything
-- else — the same shape as guard_member_self_update(), and with the same
-- property: A COLUMN ADDED LATER COUNTS AS HUMAN, which is the safe direction.
-- It errs toward keeping a row rather than deleting one.
create or replace function tg_promote_edited_demo_row() returns trigger
language plpgsql set search_path = public as $$
declare a jsonb; b jsonb; k text;
begin
  -- Nothing to promote, or the demo generator / assignment engine is writing.
  if not old.is_demo then return new; end if;
  if coalesce(current_setting('studiior.demo_generating', true), '') = '1' then return new; end if;
  if coalesce(current_setting('studiior.assigning', true), '') = '1' then return new; end if;
  -- No signed-in person means no person edited it.
  if auth.uid() is null then return new; end if;

  a := to_jsonb(new); b := to_jsonb(old);
  foreach k in array (string_to_array(coalesce(tg_argv[0], ''), ',') || array['is_demo']) loop
    a := a - btrim(k); b := b - btrim(k);
  end loop;

  if a is distinct from b then
    new.is_demo := false;
  end if;
  return new;
end $$;

drop trigger if exists members_promote_demo on members;
create trigger members_promote_demo before update on members for each row
  execute function tg_promote_edited_demo_row(
    'updated_at,first_visit_at,last_visit_at,lifetime_visits,current_streak,health_band,health_reason,health_signals,health_computed_at');

drop trigger if exists instructors_promote_demo on instructors;
create trigger instructors_promote_demo before update on instructors for each row
  execute function tg_promote_edited_demo_row('updated_at');

drop trigger if exists class_types_promote_demo on class_types;
create trigger class_types_promote_demo before update on class_types for each row
  execute function tg_promote_edited_demo_row('updated_at');

drop trigger if exists rooms_promote_demo on rooms;
create trigger rooms_promote_demo before update on rooms for each row
  execute function tg_promote_edited_demo_row('updated_at');

drop trigger if exists plans_promote_demo on membership_plans;
create trigger plans_promote_demo before update on membership_plans for each row
  execute function tg_promote_edited_demo_row('updated_at');

drop trigger if exists series_promote_demo on class_series;
create trigger series_promote_demo before update on class_series for each row
  execute function tg_promote_edited_demo_row('updated_at');

-- class_occurrences too: moving a demo class or putting your own instructor on
-- it is a personal edit. booked_count and the derived staffing columns are
-- system, so a demo member booking a demo class does not promote it.
drop trigger if exists occurrences_promote_demo on class_occurrences;
create trigger occurrences_promote_demo before update on class_occurrences for each row
  execute function tg_promote_edited_demo_row(
    'updated_at,booked_count,waitlist_count,series_slot_at,staffing,is_exception,assigned_by');

revoke execute on function tg_promote_edited_demo_row() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. The purge says what it will delete and waits
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- generate_demo_data, rebuilt from migration 057's FILE
-- -----------------------------------------------------------------------------
-- 057 is the latest migration that OWNS this function; migration 017's text is
-- a version behind and loses 057's `on conflict (series_id, starts_at)` fix.
-- And not from pg_get_functiondef() either: twice this session a copy taken
-- from the live database contained an earlier, wrong draft of the very
-- migration being written, because that database had already had it applied.
-- THE RULE BOTH MISTAKES POINT AT: rebuild from the latest migration FILE that
-- defines the function, never from the database you have been iterating on.
CREATE OR REPLACE FUNCTION public.generate_demo_data(p_studio_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tz        text;
  cur       char(3);
  loc       uuid;
  today     date;
  monday    date;
  n_occ     int := 0;
  n_bk      int := 0;
  n_ci      int := 0;
  n_future  int := 0;
  nxt        record;
  res        book_class_result;
  owner_uid  uuid;
  caller_uid text;
begin
  -- Its own writes are not a human editing a record, so they must not promote
  -- anything out of the demo set. Transaction-local.
  perform set_config('studiior.demo_generating', '1', true);

  if not is_platform_admin() then
    raise exception 'only a platform admin may generate demo data'
      using errcode = 'PT403';
  end if;

  select timezone, currency into tz, cur from studios where id = p_studio_id;
  if tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  select id into loc from locations
   where studio_id = p_studio_id and is_primary limit 1;
  if loc is null then
    insert into locations (studio_id, name, timezone, is_primary)
    values (p_studio_id, 'Main', tz, true) returning id into loc;
  end if;

  today  := (now() at time zone tz)::date;
  monday := today - ((extract(isodow from today)::int) - 1);

  -- --- rooms, class types, instructors ------------------------------------
  create temp table _d_room (id uuid, name text, cap int) on commit drop;
  insert into _d_room
  select md5(p_studio_id::text || ':room:' || v.name)::uuid, v.name, v.cap
    from (values ('Reformer Studio', 8), ('Mat Studio', 12)) v(name, cap);
  insert into rooms (id, studio_id, location_id, name, capacity, is_demo)
  select id, p_studio_id, loc, name, cap, true from _d_room
  on conflict (id) do nothing;
  -- Every demo id is derived from the studio id, so a row the purge KEPT —
  -- because a human edited it into a real record, or because a real membership
  -- sits on it — survives with the id the next generation wants. The studio's
  -- record wins and the generator steps around it. Salting the ids instead
  -- would give up the determinism that makes two runs identical.

  create temp table _d_ct (id uuid, name text, mins int, cap int, diff text) on commit drop;
  insert into _d_ct
  select md5(p_studio_id::text || ':ct:' || v.name)::uuid, v.name, v.mins, v.cap, v.diff
    from (values
      ('Reformer Flow', 50, 8, 'intermediate'),
      ('Reformer Beginners', 50, 8, 'beginner'),
      ('Mat Pilates', 50, 12, 'all levels'),
      ('Barre', 45, 12, 'all levels')) v(name, mins, cap, diff);
  insert into class_types (id, studio_id, name, duration_minutes, default_capacity, difficulty, is_demo)
  select id, p_studio_id, name, mins, cap, diff, true from _d_ct
  on conflict (id) do nothing;
  -- Every demo id is derived from the studio id, so a row the purge KEPT —
  -- because a human edited it into a real record, or because a real membership
  -- sits on it — survives with the id the next generation wants. The studio's
  -- record wins and the generator steps around it. Salting the ids instead
  -- would give up the determinism that makes two runs identical.

  create temp table _d_inst (id uuid, name text) on commit drop;
  insert into _d_inst
  select md5(p_studio_id::text || ':inst:' || v.name)::uuid, v.name
    from (values ('Malaya Fictitious'), ('Bayani Notreal'), ('Amihan Invented')) v(name);
  insert into instructors (id, studio_id, staff_id, display_name, is_demo)
  select id, p_studio_id, null, name, true from _d_inst
  on conflict (id) do nothing;
  -- Every demo id is derived from the studio id, so a row the purge KEPT —
  -- because a human edited it into a real record, or because a real membership
  -- sits on it — survives with the id the next generation wants. The studio's
  -- record wins and the generator steps around it. Salting the ids instead
  -- would give up the determinism that makes two runs identical.

  -- --- plans, priced for the studio's own currency -------------------------
  -- Magnitudes suit PHP, which is what Reform Collective sells in. A studio on
  -- another currency gets the same shapes and should reprice them.
  create temp table _d_plan (id uuid, key text, name text, ptype plan_type,
                             price int, interval_ billing_interval, credits int,
                             per_period int, validity int) on commit drop;
  insert into _d_plan values
    (md5(p_studio_id::text || ':plan:unlimited')::uuid, 'unlimited', 'Unlimited Monthly', 'recurring',  550000, 'month', null, null, null),
    (md5(p_studio_id::text || ':plan:eight')::uuid, 'eight',     '8 Classes Monthly', 'recurring',  400000, 'month', null, 8,    null),
    (md5(p_studio_id::text || ':plan:pack')::uuid, 'pack',      '10-Class Pack',     'class_pack', 500000, null,    10,   null, 180),
    (md5(p_studio_id::text || ':plan:dropin')::uuid, 'dropin',    'Drop-in',           'drop_in',     65000, null,    1,    null, 30);
  insert into membership_plans
    (id, studio_id, name, type, price_cents, currency, billing_interval,
     credits, credits_per_period, validity_days, is_demo)
  select id, p_studio_id, name, ptype, price, cur, interval_, credits, per_period, validity, true
    from _d_plan
  on conflict (id) do nothing;
  -- Every demo id is derived from the studio id, so a row the purge KEPT —
  -- because a human edited it into a real record, or because a real membership
  -- sits on it — survives with the id the next generation wants. The studio's
  -- record wins and the generator steps around it. Salting the ids instead
  -- would give up the determinism that makes two runs identical.

  -- --- a normal week, materialised -----------------------------------------
  create temp table _d_series (id uuid, ct uuid, inst uuid, room uuid,
                               name text, dow int, tod time, cap int) on commit drop;
  insert into _d_series
  select md5(p_studio_id::text || ':series:' || v.ct || v.dow || v.tod)::uuid,
         (select id from _d_ct where name = v.ct),
         (select id from _d_inst where name = v.inst),
         (select id from _d_room where name = v.room),
         v.ct, v.dow, v.tod, (select cap from _d_room where name = v.room)
    from (values
      ('Reformer Flow','Malaya Fictitious','Reformer Studio',1,'07:00'::time),
      ('Mat Pilates','Bayani Notreal','Mat Studio',1,'18:30'),
      ('Reformer Beginners','Amihan Invented','Reformer Studio',2,'09:30'),
      ('Barre','Bayani Notreal','Mat Studio',2,'19:00'),
      ('Reformer Flow','Malaya Fictitious','Reformer Studio',3,'07:00'),
      ('Reformer Flow','Malaya Fictitious','Reformer Studio',3,'18:00'),
      ('Mat Pilates','Bayani Notreal','Mat Studio',4,'09:30'),
      ('Barre','Bayani Notreal','Mat Studio',4,'18:30'),
      ('Reformer Flow','Malaya Fictitious','Reformer Studio',5,'07:00'),
      ('Mat Pilates','Amihan Invented','Mat Studio',5,'12:00'),
      ('Reformer Flow','Malaya Fictitious','Reformer Studio',6,'09:00'),
      ('Barre','Bayani Notreal','Mat Studio',6,'10:30'),
      ('Mat Pilates','Amihan Invented','Mat Studio',7,'10:00')
    ) v(ct, inst, room, dow, tod);

  insert into class_series
    (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
     capacity, duration_minutes, rrule, starts_on, time_of_day, is_demo)
  select s.id, p_studio_id, loc, s.ct, s.name, s.inst, s.room, s.cap,
         (select mins from _d_ct where id = s.ct),
         'FREQ=WEEKLY;BYDAY=' || (array['MO','TU','WE','TH','FR','SA','SU'])[s.dow],
         monday - interval '26 weeks', s.tod, true
    from _d_series s;

  -- Local wall-clock converted to UTC per occurrence, never by adding fixed
  -- intervals — a 07:00 class stays 07:00 across DST (CLAUDE.md).
  insert into class_occurrences
    (id, studio_id, location_id, series_id, class_type_id, name, instructor_id,
     room_id, capacity, starts_at, ends_at, status, is_demo, series_slot_at)
  select md5(s.id::text || ':w:' || w::text)::uuid,
         p_studio_id, loc, s.id, s.ct, s.name, s.inst, s.room, s.cap,
         ((monday + (w * 7) + (s.dow - 1)) + s.tod) at time zone tz,
         ((monday + (w * 7) + (s.dow - 1)) + s.tod) at time zone tz
           + make_interval(mins => (select mins from _d_ct where id = s.ct)),
         case when ((monday + (w * 7) + (s.dow - 1)) + s.tod) at time zone tz < now()
              then 'completed'::occurrence_status else 'scheduled'::occurrence_status end,
         true,
         ((monday + (w * 7) + (s.dow - 1)) + s.tod) at time zone tz
    from _d_series s cross join generate_series(-26, 4) w
  -- Since migration 057 the class_series insert above fires the materialise
  -- trigger, so the forward half of this range already exists — made by the
  -- real generator rather than by the demo one, which is the right way round.
  -- The target is named because a bare ON CONFLICT would try the DEFERRABLE
  -- instructor exclusion as an arbiter, which Postgres refuses.
  on conflict (series_id, starts_at) where series_id is not null do nothing;
  get diagnostics n_occ = row_count;

  -- --- members -------------------------------------------------------------
  -- freq is visits per week while active. recent_mult scales that over the last
  -- recent_days, which is how the `expiring` cohort ends up below 60% of its own
  -- prior period. bad_rate is the share of recent bookings that become a late
  -- cancel or a no-show, which is how `drift` fires signal 2.
  create temp table _d_member (
    id uuid, idx int, cohort text, first_name text, last_name text,
    joined_on date, status member_status, freq numeric,
    active_from date, active_to date, plan text,
    recent_mult numeric default 1, recent_days int default 0, bad_rate numeric default 0
  ) on commit drop;

  insert into _d_member (id, idx, cohort, first_name, last_name, joined_on, status,
                         freq, active_from, active_to, plan, recent_mult, recent_days, bad_rate)
  values
    -- 1. the backbone: still coming, own rhythm intact
    (md5(p_studio_id::text||':m:1')::uuid, 1,'regular','Liwayway','Fictitious', today-540,'active',2.8, today-182, today-2,'unlimited',1,0,0.04),
    (md5(p_studio_id::text||':m:2')::uuid, 2,'regular','Dakila','Notreal',      today-480,'active',2.2, today-182, today-2,'unlimited',1,0,0.04),
    (md5(p_studio_id::text||':m:3')::uuid, 3,'regular','Marikit','Madeup',      today-410,'active',3.1, today-182, today-1,'unlimited',1,0,0.04),
    (md5(p_studio_id::text||':m:4')::uuid, 4,'regular','Tala','Invented',       today-300,'active',2.6, today-182, today-2,'unlimited',1,0,0.04),
    -- 2. eight a month
    (md5(p_studio_id::text||':m:5')::uuid, 5,'eight','Amihan','Synthetic',      today-330,'active',1.8, today-182, today-2,'eight',1,0,0.04),
    (md5(p_studio_id::text||':m:6')::uuid, 6,'eight','Bituin','Placeholder',    today-290,'active',1.6, today-182, today-3,'eight',1,0,0.04),
    (md5(p_studio_id::text||':m:7')::uuid, 7,'eight','Halina','Sampleton',      today-240,'active',2.0, today-182, today-2,'eight',1,0,0.04),
    -- 3. pack holders
    (md5(p_studio_id::text||':m:8')::uuid, 8,'pack','Lakan','Mockup',           today-270,'active',1.1, today-182, today-3,'pack',1,0,0.04),
    (md5(p_studio_id::text||':m:9')::uuid, 9,'pack','Sinag','Stand-in',         today-210,'active',0.9, today-182, today-3,'pack',1,0,0.04),
    (md5(p_studio_id::text||':m:10')::uuid, 10,'pack','Diwata','Simulated',       today-160,'active',1.3, today-160, today-3,'pack',1,0,0.04),
    -- 4. rhythm deviation — signal 1. Still "active" everywhere else.
    (md5(p_studio_id::text||':m:11')::uuid, 11,'lapsing','Ligaya','Contrived',    today-400,'active',2.4, today-182, today-26,'unlimited',1,0,0.08),
    (md5(p_studio_id::text||':m:12')::uuid, 12,'lapsing','Katipunan','Illusory',  today-350,'active',2.1, today-182, today-34,'eight',1,0,0.08),
    (md5(p_studio_id::text||':m:13')::uuid, 13,'lapsing','Batangas','Spurious',   today-280,'active',1.8, today-182, today-45,'pack',1,0,0.08),
    (md5(p_studio_id::text||':m:14')::uuid, 14,'lapsing','Mayumi','Bogus',        today-220,'active',2.2, today-182, today-60,'eight',1,0,0.08),
    -- 5. brand new, still finding their feet
    (md5(p_studio_id::text||':m:15')::uuid, 15,'new','Alon','Nonexistent',        today-6, 'active',1.4, today-6,  today-1,'dropin',1,0,0.05),
    (md5(p_studio_id::text||':m:16')::uuid, 16,'new','Haraya','Fictional',        today-11,'active',1.2, today-11, today-2,'pack',1,0,0.05),
    -- 6. one class, never came back
    (md5(p_studio_id::text||':m:17')::uuid, 17,'onceonly','Perlas','Fanciful',    today-48, 'inactive',0, today-48, today-48,'dropin',1,0,0),
    (md5(p_studio_id::text||':m:18')::uuid, 18,'onceonly','Kidlat','Apocryphal',  today-115,'inactive',0, today-115,today-115,'dropin',1,0,0),
    (md5(p_studio_id::text||':m:19')::uuid, 19,'onceonly','Sampaguita','Fabled',  today-170,'inactive',0, today-170,today-170,'dropin',1,0,0),
    -- 7. payment state — signal 4
    (md5(p_studio_id::text||':m:20')::uuid, 20,'pastdue','Narra','Untrue',        today-320,'active',2.0, today-182, today-2,'eight',1,0,0.04),
    -- 8. booking-to-attendance drift — signal 2. Still booking, stopped turning up.
    (md5(p_studio_id::text||':m:21')::uuid, 21,'drift','Bagwis','Imaginary',      today-300,'active',2.0, today-182, today-2,'unlimited',1,42,0.68),
    (md5(p_studio_id::text||':m:22')::uuid, 22,'drift','Luntian','Concocted',     today-260,'active',1.8, today-182, today-2,'eight',1,42,0.68),
    -- 9. stalled first month — signal 3
    (md5(p_studio_id::text||':m:23')::uuid, 23,'stalled','Ulan','Imagined',       today-24,'active',0.4, today-24, today-19,'dropin',1,0,0),
    (md5(p_studio_id::text||':m:24')::uuid, 24,'stalled','Hangin','Pretend',      today-31,'active',0.3, today-31, today-27,'pack',1,0,0),
    -- 10. renewal approaching, usage falling away — signal 5
    (md5(p_studio_id::text||':m:25')::uuid, 25,'expiring','Araw','Hypothetical',  today-260,'active',2.4, today-182, today-2,'eight',0.30, greatest(extract(day from today)::int - 1, 1), 0.06),
    (md5(p_studio_id::text||':m:26')::uuid, 26,'expiring','Buwan','Notional',     today-300,'active',2.6, today-182, today-2,'eight',0.25, greatest(extract(day from today)::int - 1, 1), 0.06);

  insert into members
    (id, studio_id, first_name, last_name, email, phone, status, joined_on,
     source, marketing_opt_in, waiver_signed_at, is_demo)
  select m.id, p_studio_id, m.first_name, m.last_name,
         lower(m.first_name) || '.' || lower(m.last_name) || '@example.com',
         '+63 917 ' || lpad((100 + m.idx)::text, 6, '0'),
         m.status, m.joined_on,
         (array['walk-in','instagram','referral','google','event'])[1 + (m.idx % 5)],
         (m.idx % 3 <> 0),
         (m.joined_on + time '10:00') at time zone tz,
         true
    from _d_member m
  on conflict (id) do nothing;

  -- A member the purge KEPT because somebody edited them into a real person is
  -- the studio's, not the generator's. Dropping them from the working set stops
  -- the demo attaching fake memberships, bookings and check-ins to a real
  -- record — which is also what collided on bookings_one_live_per_member, a
  -- partial unique index that no ON CONFLICT (id) could have caught.
  delete from _d_member dm
   where exists (select 1 from members m
                  where m.id = dm.id and m.studio_id = p_studio_id and not m.is_demo);

  -- Every demo id is derived from the studio id, so a row the purge KEPT —
  -- because a human edited it into a real record, or because a real membership
  -- sits on it — survives with the id the next generation wants. The studio's
  -- record wins and the generator steps around it. Salting the ids instead
  -- would give up the determinism that makes two runs identical.

  -- --- memberships ---------------------------------------------------------
  insert into memberships
    (studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
     current_period_start, current_period_end, renews_on, credits_remaining,
     auto_renew, is_demo)
  select p_studio_id, m.id, p.id,
         case when m.cohort = 'pastdue' then 'past_due'::membership_status
              else 'active'::membership_status end,
         p.price, cur, m.joined_on,
         (date_trunc('month', today))::timestamptz,
         (date_trunc('month', today) + interval '1 month')::timestamptz,
         -- The expiring cohort renews inside signal 5's 21-day window; everyone
         -- else sits outside it.
         --
         -- Real memberships renew on their own anniversary, not all on the 1st.
         -- Dating them all to the month boundary put the whole studio inside the
         -- window at month end, and signal 5 fired for anyone whose usage dipped
         -- — correct behaviour on incorrect data. Staggering it is both truer to
         -- life and what keeps each cohort demonstrating its own signal.
         case when m.cohort = 'expiring' then today + 9
              else today + 24 + (m.idx % 30) end,
         case p.key when 'eight' then 8 else null end,
         true, true
    from _d_member m join _d_plan p on p.key = m.plan
   where m.plan in ('unlimited','eight');

  insert into memberships
    (studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
     expires_on, credits_remaining, auto_renew, is_demo)
  select p_studio_id, m.id, p.id, 'active', p.price, cur,
         greatest(m.active_from, today - 150),
         greatest(m.active_from, today - 150) + 180, 10, false, true
    from _d_member m join _d_plan p on p.key = 'pack'
   where m.plan = 'pack';

  insert into payments
    (studio_id, member_id, membership_id, amount_cents, currency, status,
     description, card_brand, card_last4, paid_at, failure_code, attempt_count,
     created_at, is_demo)
  select p_studio_id, ms.member_id, ms.id, ms.price_cents, cur,
         case when ms.status = 'past_due' and k = 0 then 'failed'::payment_status
              else 'succeeded'::payment_status end,
         'Monthly membership', 'visa', lpad((1000 + m.idx)::text, 4, '0'),
         case when ms.status = 'past_due' and k = 0 then null
              else (date_trunc('month', today) - make_interval(months => k))::timestamptz end,
         case when ms.status = 'past_due' and k = 0 then 'card_declined' end,
         case when ms.status = 'past_due' and k = 0 then 3 else 1 end,
         (date_trunc('month', today) - make_interval(months => k))::timestamptz,
         true
    from memberships ms
    join _d_member m on m.id = ms.member_id
    cross join generate_series(0, 2) k
   where ms.studio_id = p_studio_id and ms.is_demo and m.plan in ('unlimited','eight')
     and (date_trunc('month', today) - make_interval(months => k))::date >= m.joined_on;

  -- --- attendance ----------------------------------------------------------
  create temp table _d_attend on commit drop as
  select m.id as member_id, o.id as occurrence_id, o.starts_at, m.idx, m.cohort,
         m.bad_rate,
         case when m.recent_days > 0
                   and (o.starts_at at time zone tz)::date >= today - m.recent_days
              then m.bad_rate else 0.04 end as eff_bad,
         false as pinned,
         abs(hashtextextended(m.id::text || o.id::text, 42)) as h
    from _d_member m
    join class_occurrences o
      on o.studio_id = p_studio_id and o.is_demo
     and o.starts_at < now()
     and (o.starts_at at time zone tz)::date between m.active_from and m.active_to
   where m.freq > 0
     and (abs(hashtextextended(m.id::text || o.id::text, 42)) % 1000)
         < (m.freq
            * case when m.recent_days > 0
                     and (o.starts_at at time zone tz)::date >= today - m.recent_days
                   then m.recent_mult else 1 end
            * 1000 / 13);

  -- Respect the room: keep the earliest-hashed and drop the overflow rather
  -- than seeding an over-capacity class.
  delete from _d_attend a
   using (select member_id, occurrence_id,
                 row_number() over (partition by occurrence_id order by h) as rn
            from _d_attend) ranked
   join class_occurrences o on o.id = ranked.occurrence_id
   where a.member_id = ranked.member_id and a.occurrence_id = ranked.occurrence_id
     and ranked.rn > o.capacity;

  -- Pins run AFTER the prune, into classes that still have a seat.
  --
  -- Running them before meant the prune could delete the one visit that defined
  -- a cohort: a one-and-done member with no visits is a lead, and a "healthy
  -- regular" whose most recent visit was dropped lands eighteen days stale and
  -- trips signal 1. A cohort defined by its visit count cannot have that count
  -- left to a hash.
  insert into _d_attend (member_id, occurrence_id, starts_at, idx, cohort, bad_rate, eff_bad, pinned, h)
  select distinct on (m.id) m.id, o.id, o.starts_at, m.idx, m.cohort, m.bad_rate, 0.04, true,
         abs(hashtextextended(m.id::text || o.id::text, 42))
    from _d_member m
    join class_occurrences o
      on o.studio_id = p_studio_id and o.is_demo and o.starts_at < now()
     and (o.starts_at at time zone tz)::date between m.active_from and m.active_to + 14
     and (select count(*) from _d_attend a2 where a2.occurrence_id = o.id) < o.capacity
   where m.cohort in ('onceonly','stalled')
     and not exists (select 1 from _d_attend a where a.member_id = m.id)
   order by m.id, o.starts_at;

  -- The cohorts that are meant to still be coming need a recent VISIT — not
  -- merely a recent row. Promoting the latest row they already have is the way
  -- to get one: a member with a 65% no-show rate almost certainly has a recent
  -- row, and skipping the pin because a row exists leaves that row a no-show,
  -- no check-in, and a stale last visit that trips signal 1 instead.
  update _d_attend a set pinned = true
    from (
      select distinct on (a2.member_id) a2.member_id, a2.occurrence_id
        from _d_attend a2
        join _d_member m2 on m2.id = a2.member_id
       where m2.cohort in ('regular','eight','pack','drift','expiring')
         and (a2.starts_at at time zone tz)::date >= m2.active_to - 3
       order by a2.member_id, a2.starts_at desc
    ) latest
   where a.member_id = latest.member_id and a.occurrence_id = latest.occurrence_id;

  -- Only members with nothing recent at all need a row inserted.
  insert into _d_attend (member_id, occurrence_id, starts_at, idx, cohort, bad_rate, eff_bad, pinned, h)
  select distinct on (m.id) m.id, o.id, o.starts_at, m.idx, m.cohort, m.bad_rate, 0.04, true,
         abs(hashtextextended(m.id::text || o.id::text, 42))
    from _d_member m
    join class_occurrences o
      on o.studio_id = p_studio_id and o.is_demo and o.starts_at < now()
     and (o.starts_at at time zone tz)::date <= m.active_to
     and (select count(*) from _d_attend a2 where a2.occurrence_id = o.id) < o.capacity
   where m.cohort in ('regular','eight','pack','drift','expiring')
     and not exists (
       select 1 from _d_attend a
        where a.member_id = m.id
          and (a.starts_at at time zone tz)::date >= m.active_to - 3)
   order by m.id, o.starts_at desc;

  insert into bookings
    (id, studio_id, occurrence_id, member_id, status, source, payment_source,
     membership_id, booked_at, cancelled_at, is_late_cancel, is_demo)
  select gen_random_uuid(), p_studio_id, a.occurrence_id, a.member_id,
         -- The drift cohort attended normally until recently. Applying their
         -- bad rate across all history would leave them with almost no visits
         -- at all, and rhythm deviation — a higher-priority signal — would fire
         -- first and hide the thing they exist to demonstrate.
         case when a.pinned then 'attended'::booking_status
              when (a.h % 100) < (a.eff_bad * 60) then 'no_show'::booking_status
              when (a.h % 100) < (a.eff_bad * 100) then 'late_cancelled'::booking_status
              else 'attended'::booking_status end,
         'member',
         case m.plan when 'unlimited' then 'membership'::payment_source
                     when 'eight'     then 'membership'::payment_source
                     when 'pack'      then 'class_pack'::payment_source
                     else 'drop_in'::payment_source end,
         ms.id, a.starts_at - interval '3 days',
         case when not a.pinned and (a.h % 100) >= (a.eff_bad * 60)
               and (a.h % 100) <  (a.eff_bad * 100)
              then a.starts_at - interval '2 hours' end,
         (not a.pinned and (a.h % 100) >= (a.eff_bad * 60)
            and (a.h % 100) < (a.eff_bad * 100)),
         true
    from _d_attend a
    join _d_member m on m.id = a.member_id
    left join memberships ms on ms.member_id = a.member_id and ms.is_demo;
  get diagnostics n_bk = row_count;

  -- Cohorts meant to read as healthy must not trip signal 2 by hash luck. A
  -- low-frequency pack member might have only four bookings in six weeks, and
  -- two unlucky draws is 50% — over the 40% bar, on a sample far too small to
  -- mean anything. Done before check-ins are written, so every attended booking
  -- still gets its visit and the data stays coherent.
  update bookings b
     set status = 'attended', cancelled_at = null, is_late_cancel = false
    from _d_member m
   where m.id = b.member_id and b.is_demo
     and m.cohort in ('regular','eight','pack','expiring')
     and b.booked_at >= now() - interval '6 weeks'
     and b.status in ('no_show','late_cancelled');

  -- Placed inside the §8 window, so the check-in trigger accepts them without
  -- the studio-wide escape hatch being touched.
  insert into check_ins
    (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method, is_demo)
  select p_studio_id, b.id, b.member_id, b.occurrence_id,
         o.starts_at - make_interval(mins => (5 + (abs(hashtextextended(b.id::text, 7)) % 20))::int),
         (array['qr','staff','kiosk','self'])[1 + (abs(hashtextextended(b.id::text, 9)) % 4)]::checkin_method,
         true
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   -- Scoped to this studio, not just to is_demo. Every other statement in this
   -- function reaches its rows through _d_member, whose ids are derived from
   -- p_studio_id and so cannot belong to anyone else; this one goes straight at
   -- bookings, and without the studio it re-selects the demo bookings of every
   -- studio generated before it and dies on check_ins_booking_id_key. Which
   -- means demo data worked exactly once per database — fine on a laptop with
   -- one studio, and broken for the second design partner to ask for it.
   where b.studio_id = p_studio_id and b.is_demo and b.status = 'attended';
  get diagnostics n_ci = row_count;

  -- The expiring cohort is defined by a ratio — this period under 60% of last —
  -- so the ratio is set, not sampled. Left to the hash it lands wherever the
  -- month boundary and capacity pruning leave it, and the cohort stops
  -- demonstrating the signal it exists for. Deleting the booking takes its
  -- check-in with it, which is what "attended fewer classes" actually looks
  -- like; trimming only the check-in would leave an attended booking with no
  -- visit behind it.
  delete from bookings b
   where b.id in (
     select cur.booking_id
       from (
         select ci.booking_id, ci.member_id,
                row_number() over (partition by ci.member_id
                                   order by ci.checked_in_at desc) as rn
           from check_ins ci
           join _d_member m on m.id = ci.member_id
          where m.cohort = 'expiring'
            and (ci.checked_in_at at time zone tz)::date
                >= date_trunc('month', today)::date
       ) cur
       join (
         select ci.member_id, count(*) as n
           from check_ins ci
           join _d_member m on m.id = ci.member_id
          where m.cohort = 'expiring'
            and (ci.checked_in_at at time zone tz)::date
                between (date_trunc('month', today) - interval '1 month')::date
                    and (date_trunc('month', today)::date - 1)
          group by ci.member_id
       ) prior on prior.member_id = cur.member_id
      where cur.rn > floor(prior.n * 0.4)
        and cur.booking_id is not null);

  update class_occurrences o
     set booked_count   = coalesce(c.seats, 0),
         waitlist_count = coalesce(c.waiting, 0)
    from (select occurrence_id,
                 count(*) filter (where status in ('booked','attended','no_show')) as seats,
                 count(*) filter (where status = 'waitlisted') as waiting
            from bookings where studio_id = p_studio_id group by occurrence_id) c
   where o.id = c.occurrence_id;

  perform recompute_member_stats(p_studio_id);

  -- --- next week's bookings, through the real function ---------------------
  --
  -- book_class() decides who may book, and a platform admin is staff of no
  -- studio, so calling it directly is refused — correctly.
  --
  -- The first attempt here was `set_config('role','service_role')` to present
  -- as the backend. PostgreSQL refuses that inside a SECURITY DEFINER function
  -- ("cannot set parameter role within security-definer function"), and the
  -- refusal is right: a definer function silently switching roles is how
  -- privilege escalation gets written by accident.
  --
  -- So the bookings are made as the studio's owner instead, which is who would
  -- actually make them. auth.uid() reads a custom GUC, and a custom GUC can be
  -- set here; book_class then sees an owner of this studio and authorises on
  -- its own terms with nothing relaxed. Scoped to the transaction, and put back
  -- immediately after.
  select ss.user_id into owner_uid
    from studio_staff ss
   where ss.studio_id = p_studio_id and ss.role = 'owner' and ss.status = 'active'
   order by ss.joined_at limit 1;

  if owner_uid is not null then
  caller_uid := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  for nxt in
    select m.id as member_id, o.id as occurrence_id
      from _d_member m
      join class_occurrences o
        on o.studio_id = p_studio_id and o.is_demo and o.status = 'scheduled'
       and o.starts_at between now() and now() + interval '7 days'
     where m.cohort in ('regular','eight','pack','drift','expiring')
       and (abs(hashtextextended(m.id::text || o.id::text, 99)) % 100) < 18
     order by o.starts_at
  loop
    res := book_class(nxt.occurrence_id, nxt.member_id, 'staff');
    if res.failure_reason is null then
      n_future := n_future + 1;
      update bookings set is_demo = true where id = res.booking_id;
    end if;
  end loop;
  perform set_config('request.jwt.claim.sub', coalesce(caller_uid, ''), true);
  end if;

  -- EVERYTHING A DEMO SERIES CAUSED IS DEMO DATA. Since migration 057 the
  -- class_series insert above fires a trigger that materialises twelve months
  -- of occurrences, and those come out is_demo FALSE — the generator never
  -- touched them. A demo studio then filled with rows the purge could not
  -- delete by flag and could only reach by cascading off the series, which is
  -- exactly how production lost 1,036 real classes.
  update class_occurrences o
     set is_demo = true
   where o.studio_id = p_studio_id
     and o.series_id in (select s.id from class_series s
                          where s.studio_id = p_studio_id and s.is_demo);

  return jsonb_build_object(
    'studio_id', p_studio_id, 'timezone', tz, 'currency', cur,
    'occurrences', n_occ, 'members', (select count(*) from _d_member),
    'historical_bookings', n_bk, 'check_ins', n_ci, 'upcoming_bookings', n_future);
end $function$
;
