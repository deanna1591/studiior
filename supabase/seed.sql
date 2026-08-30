-- =============================================================================
-- STUDIIOR — SEED: Reform Collective, tenant one
--
-- Runs automatically on `supabase db reset`. Local development data only.
--
-- SYNTHETIC. Every name is obviously invented and every address is
-- @example.com (RFC 2606, reserved, cannot receive mail). No real member PII
-- belongs in this file, ever — the live Reform Collective tenant is production
-- data (CLAUDE.md) and must never be copied here.
--
-- Idempotent: the whole thing is one transaction-scoped block that returns
-- early if the studio already exists, so re-running is a no-op.
--
-- Disjoint from the test suites by construction:
--   11111111-… seed          aaaaaaaa-/bbbbbbbb-… rls_test
--   cccccccc-… concurrency   ffffffff-…           book_class
-- Emails are @example.com here and @test in the suites.
--
-- Shape of the data, so the AI features have something real to read later
-- (Business Rules §11):
--   * 30 members across six cohorts, joined_on spread over 18 months
--   * attendance generated from a deterministic hash, not random(), so two
--     resets produce identical data and a failing query stays reproducible
--   * five members drift into retention_risk (last visit > 2x their own
--     median gap, minimum 10 days)
--   * four are new_member_stalled (joined <=30 days, under 2 visits)
--   * one membership sits in past_due, so payment_failed has a subject
--   * four one-and-done members who never came back after a single class
--
-- Occurrences are materialised 26 weeks back and 4 weeks forward. History
-- starts later than the earliest joined_on on purpose: a studio migrating from
-- its previous system has members older than its booking history, and every
-- derived counter here is computed from the rows actually seeded rather than
-- asserted, so nothing claims a visit that has no check-in behind it.
-- =============================================================================

do $$
declare
  s          uuid := '11111111-0000-0000-0000-000000000001';  -- studio
  loc        uuid := '11111111-0000-0000-0000-000000000010';
  tz         text := 'Europe/Prague';
  cur        char(3) := 'CZK';
  room_ref   uuid := '11111111-0000-0000-0000-000000000021';
  room_mat   uuid := '11111111-0000-0000-0000-000000000022';
  -- class types
  ct_flow    uuid := '11111111-0000-0000-0000-000000000031';
  ct_begin   uuid := '11111111-0000-0000-0000-000000000032';
  ct_mat     uuid := '11111111-0000-0000-0000-000000000033';
  ct_barre   uuid := '11111111-0000-0000-0000-000000000034';
  -- instructors
  in_ada     uuid := '11111111-0000-0000-0000-000000000041';
  in_bo      uuid := '11111111-0000-0000-0000-000000000042';
  in_cleo    uuid := '11111111-0000-0000-0000-000000000043';
  -- staff rows
  st_owner   uuid := '11111111-0000-0000-0000-000000000051';
  st_mgr     uuid := '11111111-0000-0000-0000-000000000052';
  st_desk    uuid := '11111111-0000-0000-0000-000000000053';
  st_instr   uuid := '11111111-0000-0000-0000-000000000054';
  -- auth users
  au_owner   uuid := '11111111-0000-0000-0000-000000000061';
  au_mgr     uuid := '11111111-0000-0000-0000-000000000062';
  au_desk    uuid := '11111111-0000-0000-0000-000000000063';
  au_instr   uuid := '11111111-0000-0000-0000-000000000064';
  -- plans
  pl_unl     uuid := '11111111-0000-0000-0000-000000000071';
  pl_eight   uuid := '11111111-0000-0000-0000-000000000072';
  pl_pack    uuid := '11111111-0000-0000-0000-000000000073';
  pl_drop    uuid := '11111111-0000-0000-0000-000000000074';

  today      date := (now() at time zone tz)::date;
  monday     date;                    -- Monday of the current studio-local week
  n_occ      int;
  n_bk       int;
  n_ci       int;
  n_future   int := 0;
  nxt        record;
  res        book_class_result;
begin
  if exists (select 1 from studios where id = s) then
    raise notice 'seed: Reform Collective already present, nothing to do';
    return;
  end if;

  monday := today - ((extract(isodow from today)::int) - 1);

  -- ===========================================================================
  -- 1. Studio, settings, location, rooms
  -- ===========================================================================

  insert into studios (id, name, slug, timezone, currency, country, brand_color, status)
  values (s, 'Reform Collective', 'reform', tz, cur, 'CZ', '#2F4F4F', 'active');

  -- Everything at the documented defaults. A design partner moving one of
  -- these is a deliberate act, so the seed should not pre-empt it.
  --
  -- onboarding_completed_at is set because Reform Collective has been running
  -- for eighteen months in this data. Leaving it null would put a studio with
  -- 30 members and 400 classes behind a setup wizard it never ran, and every
  -- staff screen would bounce to /welcome.
  insert into studio_settings (studio_id, onboarding_completed_at)
  values (s, now() - interval '18 months');

  insert into locations (id, studio_id, name, address, timezone, is_primary)
  values (loc, s, 'Vinohrady',
          jsonb_build_object('line1','Fictional Street 1','city','Prague',
                             'postal_code','120 00','country','CZ'),
          tz, true);

  insert into rooms (id, studio_id, location_id, name, capacity, color) values
    (room_ref, s, loc, 'Reformer Studio',  8, '#8FBC8F'),
    (room_mat, s, loc, 'Mat Studio',      12, '#DEB887');

  -- ===========================================================================
  -- 2. Class types
  -- ===========================================================================

  insert into class_types (id, studio_id, name, description, duration_minutes,
                           default_capacity, difficulty, color) values
    (ct_flow,  s, 'Reformer Flow',      'Continuous reformer work, some experience assumed.', 50,  8, 'intermediate', '#2F4F4F'),
    (ct_begin, s, 'Reformer Beginners', 'Springs, straps and vocabulary. Start here.',        50,  8, 'beginner',     '#8FBC8F'),
    (ct_mat,   s, 'Mat Pilates',        'Classical mat work, no equipment.',                  50, 12, 'all levels',   '#DEB887'),
    (ct_barre, s, 'Barre',              'Small range, high repetition, borrowed from ballet.',45, 12, 'all levels',   '#CD853F');

  -- ===========================================================================
  -- 3. Staff logins and instructors
  --
  -- Local dev credentials, synthetic: every account is <role>@example.com with
  -- password 'reform-dev-password'. These exist so the local stack has
  -- something to sign in as; they are meaningless anywhere else.
  -- ===========================================================================

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at)
  select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         u.email, crypt('reform-dev-password', gen_salt('bf')), now(), now()
    from (values
      (au_owner, 'owner@example.com'),
      (au_mgr,   'manager@example.com'),
      (au_desk,  'frontdesk@example.com'),
      (au_instr, 'instructor@example.com')
    ) as u(id, email);

  insert into profiles (id, email, full_name) values
    (au_owner, 'owner@example.com',      'Dana Testerova'),
    (au_mgr,   'manager@example.com',    'Milos Fixture'),
    (au_desk,  'frontdesk@example.com',  'Petra Placeholder'),
    (au_instr, 'instructor@example.com', 'Ada Example');

  insert into studio_staff (id, studio_id, user_id, email, role, joined_at) values
    (st_owner, s, au_owner, 'owner@example.com',      'owner',      now() - interval '18 months'),
    (st_mgr,   s, au_mgr,   'manager@example.com',    'manager',    now() - interval '11 months'),
    (st_desk,  s, au_desk,  'frontdesk@example.com',  'front_desk', now() - interval '7 months'),
    (st_instr, s, au_instr, 'instructor@example.com', 'instructor', now() - interval '14 months');

  -- Ada has a login; Bo and Cleo are teaching records with no portal account,
  -- which is the common case for part-time instructors.
  insert into instructors (id, studio_id, staff_id, display_name, bio, color) values
    (in_ada,  s, st_instr, 'Ada Example',    'Reformer and mat. Teaches the 7am crowd.', '#2F4F4F'),
    (in_bo,   s, null,     'Bo Fictitious',  'Barre and mat.',                            '#CD853F'),
    (in_cleo, s, null,     'Cleo Sampleton', 'Beginners reformer.',                       '#8FBC8F');

  -- ===========================================================================
  -- 4. Plans
  -- ===========================================================================

  insert into membership_plans
    (id, studio_id, name, description, type, price_cents, currency,
     billing_interval, credits, credits_per_period, validity_days,
     visibility, sort_order)
  values
    (pl_unl,   s, 'Unlimited Monthly', 'Every class, every week.',        'recurring',  280000, cur, 'month', null, null, null, 'public', 1),
    (pl_eight, s, '8 Classes Monthly', 'Eight classes a month.',          'recurring',  180000, cur, 'month', null, 8,    null, 'public', 2),
    (pl_pack,  s, '10-Class Pack',     'Ten classes, valid six months.',  'class_pack', 550000, cur, null,    10,   null, 180,  'public', 3),
    (pl_drop,  s, 'Drop-in',           'One class.',                      'drop_in',     65000, cur, null,    1,    null, 30,   'public', 4);

  -- ===========================================================================
  -- 5. Class series — a normal week
  -- ===========================================================================

  create temp table _seed_series (
    id uuid, class_type uuid, instructor uuid, room uuid,
    name text, dow int, tod time, cap int
  ) on commit drop;

  insert into _seed_series values
    ('11111111-0000-0000-0000-000000000081', ct_flow,  in_ada,  room_ref, 'Reformer Flow',      1, '07:00',  8),
    ('11111111-0000-0000-0000-000000000082', ct_mat,   in_bo,   room_mat, 'Mat Pilates',        1, '18:30', 12),
    ('11111111-0000-0000-0000-000000000083', ct_begin, in_cleo, room_ref, 'Reformer Beginners', 2, '09:30',  8),
    ('11111111-0000-0000-0000-000000000084', ct_barre, in_bo,   room_mat, 'Barre',              2, '19:00', 12),
    ('11111111-0000-0000-0000-000000000085', ct_flow,  in_ada,  room_ref, 'Reformer Flow',      3, '07:00',  8),
    ('11111111-0000-0000-0000-000000000086', ct_flow,  in_ada,  room_ref, 'Reformer Flow',      3, '18:00',  8),
    ('11111111-0000-0000-0000-000000000087', ct_mat,   in_bo,   room_mat, 'Mat Pilates',        4, '09:30', 12),
    ('11111111-0000-0000-0000-000000000088', ct_barre, in_bo,   room_mat, 'Barre',              4, '18:30', 12),
    ('11111111-0000-0000-0000-000000000089', ct_flow,  in_ada,  room_ref, 'Reformer Flow',      5, '07:00',  8),
    ('11111111-0000-0000-0000-00000000008a', ct_mat,   in_cleo, room_mat, 'Mat Pilates',        5, '12:00', 12),
    ('11111111-0000-0000-0000-00000000008b', ct_flow,  in_ada,  room_ref, 'Reformer Flow',      6, '09:00',  8),
    ('11111111-0000-0000-0000-00000000008c', ct_barre, in_bo,   room_mat, 'Barre',              6, '10:30', 12),
    ('11111111-0000-0000-0000-00000000008d', ct_mat,   in_cleo, room_mat, 'Mat Pilates',        7, '10:00', 12);

  insert into class_series
    (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
     capacity, duration_minutes, rrule, starts_on, time_of_day, created_by)
  select ss.id, s, loc, ss.class_type, ss.name, ss.instructor, ss.room,
         ss.cap,
         case when ss.class_type = ct_barre then 45 else 50 end,
         'FREQ=WEEKLY;BYDAY=' ||
           (array['MO','TU','WE','TH','FR','SA','SU'])[ss.dow],
         monday - interval '26 weeks', ss.tod, au_owner
    from _seed_series ss;

  -- ===========================================================================
  -- 6. Occurrences — 26 weeks back, 4 weeks forward
  --
  -- Local time converted to UTC per occurrence (CLAUDE.md, Business Rules §1).
  -- NOT starts_at + interval '7 days': that drifts an hour across the DST
  -- boundary and a 7am class would stop being a 7am class.
  -- ===========================================================================

  insert into class_occurrences
    (studio_id, location_id, series_id, class_type_id, name, instructor_id,
     room_id, capacity, starts_at, ends_at, status)
  select s, loc, ss.id, ss.class_type, ss.name, ss.instructor, ss.room, ss.cap,
         ((monday + (w * 7) + (ss.dow - 1)) + ss.tod) at time zone tz,
         ((monday + (w * 7) + (ss.dow - 1)) + ss.tod) at time zone tz
           + make_interval(mins => case when ss.class_type = ct_barre then 45 else 50 end),
         case when ((monday + (w * 7) + (ss.dow - 1)) + ss.tod) at time zone tz < now()
              then 'completed'::occurrence_status
              else 'scheduled'::occurrence_status end
    from _seed_series ss
    cross join generate_series(-26, 4) w;

  get diagnostics n_occ = row_count;

  -- ===========================================================================
  -- 7. Members — 30, six cohorts
  --
  -- freq is classes per week while active; the schedule runs 13 a week, so the
  -- per-occurrence probability below is freq/13.
  -- ===========================================================================

  create temp table _seed_member (
    id uuid, idx int, cohort text, first_name text, last_name text,
    joined_on date, status member_status,
    freq numeric,            -- classes per week while active
    active_from date,        -- first week they could attend
    active_to date,          -- last week they attended (drives retention_risk)
    plan text                -- unlimited | eight | pack | dropin | none
  ) on commit drop;

  insert into _seed_member (id, idx, cohort, first_name, last_name, joined_on,
                            status, freq, active_from, active_to, plan)
  values
    -- 1. Unlimited regulars: the studio's backbone, still coming this week.
    ('11111111-0000-0000-0000-000000000101', 1,'regular','Alena','Fabricated', today-540,'active',2.8, today-182, today-2,'unlimited'),
    ('11111111-0000-0000-0000-000000000102', 2,'regular','Bohdan','Notreal',   today-480,'active',2.2, today-182, today-4,'unlimited'),
    ('11111111-0000-0000-0000-000000000103', 3,'regular','Cecilia','Madeup',   today-410,'active',3.1, today-182, today-1,'unlimited'),
    ('11111111-0000-0000-0000-000000000104', 4,'regular','Dominik','Invented', today-365,'active',2.0, today-182, today-6,'unlimited'),
    ('11111111-0000-0000-0000-000000000105', 5,'regular','Eliska','Pretend',   today-300,'active',2.6, today-182, today-3,'unlimited'),
    ('11111111-0000-0000-0000-000000000106', 6,'regular','Filip','Imaginary',  today-260,'active',1.9, today-182, today-5,'unlimited'),
    -- 2. Eight-a-month members.
    ('11111111-0000-0000-0000-000000000107', 7,'eight','Gabriela','Synthetic', today-330,'active',1.8, today-182, today-3,'eight'),
    ('11111111-0000-0000-0000-000000000108', 8,'eight','Honza','Placeholder',  today-290,'active',1.6, today-182, today-7,'eight'),
    ('11111111-0000-0000-0000-000000000109', 9,'eight','Ivana','Sampleton',    today-240,'active',2.0, today-182, today-2,'eight'),
    ('11111111-0000-0000-0000-00000000010a',10,'eight','Jakub','Dummy',        today-200,'active',1.5, today-182, today-8,'eight'),
    ('11111111-0000-0000-0000-00000000010b',11,'eight','Katerina','Faux',      today-150,'active',1.7, today-150, today-4,'eight'),
    -- 3. Pack holders, lighter and less regular.
    ('11111111-0000-0000-0000-00000000010c',12,'pack','Lukas','Mockup',        today-270,'active',1.1, today-182, today-9,'pack'),
    ('11111111-0000-0000-0000-00000000010d',13,'pack','Marketa','Stand-in',    today-210,'active',0.9, today-182, today-12,'pack'),
    ('11111111-0000-0000-0000-00000000010e',14,'pack','Nikola','Simulated',    today-160,'active',1.3, today-160, today-5,'pack'),
    ('11111111-0000-0000-0000-00000000010f',15,'pack','Ondrej','Notional',     today-120,'active',1.0, today-120, today-11,'pack'),
    ('11111111-0000-0000-0000-000000000110',16,'pack','Pavla','Hypothetical',  today-95, 'active',1.2, today-95,  today-6,'pack'),
    -- 4. Drifting away. Active, previously regular, now well past their own
    --    normal gap -> retention_risk (Business Rules §11).
    ('11111111-0000-0000-0000-000000000111',17,'lapsing','Radek','Contrived',  today-400,'active',2.4, today-182, today-27,'unlimited'),
    ('11111111-0000-0000-0000-000000000112',18,'lapsing','Sarka','Illusory',   today-350,'active',2.1, today-182, today-34,'eight'),
    ('11111111-0000-0000-0000-000000000113',19,'lapsing','Tomas','Spurious',   today-280,'active',1.8, today-182, today-41,'pack'),
    ('11111111-0000-0000-0000-000000000114',20,'lapsing','Veronika','Bogus',   today-220,'active',2.2, today-182, today-52,'eight'),
    ('11111111-0000-0000-0000-000000000115',21,'lapsing','Zdenek','Unreal',    today-190,'active',1.6, today-182, today-63,'pack'),
    -- 5. Brand new. Joined inside 30 days, one visit or none, nothing booked
    --    ahead -> new_member_stalled for the ones under two visits.
    ('11111111-0000-0000-0000-000000000116',22,'new','Adela','Nonexistent',    today-5,  'active',1.0, today-5,   today-2,'dropin'),
    ('11111111-0000-0000-0000-000000000117',23,'new','Boris','Fictional',      today-9,  'active',0.8, today-9,   today-6,'pack'),
    ('11111111-0000-0000-0000-000000000118',24,'new','Dita','Imagined',        today-14, 'active',0.5, today-14,  today-13,'dropin'),
    ('11111111-0000-0000-0000-000000000119',25,'new','Emil','Concocted',       today-21, 'active',0.6, today-21,  today-18,'dropin'),
    -- 6. One class, never came back.
    ('11111111-0000-0000-0000-00000000011a',26,'onceonly','Gita','Fanciful',   today-45, 'inactive',0, today-45, today-45,'dropin'),
    ('11111111-0000-0000-0000-00000000011b',27,'onceonly','Hugo','Apocryphal', today-110,'inactive',0, today-110,today-110,'dropin'),
    ('11111111-0000-0000-0000-00000000011c',28,'onceonly','Irena','Fabled',    today-175,'inactive',0, today-175,today-175,'dropin'),
    -- kept inside the 26 weeks of materialised history so his single visit
    -- has a class to land on; the 18-month joined_on spread comes from the
    -- regulars above, who predate the booking history on purpose
    ('11111111-0000-0000-0000-00000000011d',29,'onceonly','Jonas','Mythical',  today-170,'archived',0, today-170,today-170,'dropin'),
    -- 7. Card is failing. Membership sits past_due -> payment_failed.
    ('11111111-0000-0000-0000-00000000011e',30,'pastdue','Klara','Untrue',     today-320,'active',2.0, today-182, today-3,'eight');

  insert into members
    (id, studio_id, first_name, last_name, email, phone, status, joined_on,
     source, marketing_opt_in, waiver_signed_at)
  select m.id, s, m.first_name, m.last_name,
         lower(m.first_name) || '.' || lower(m.last_name) || '@example.com',
         '+420 700 ' || lpad((100 + m.idx)::text, 6, '0'),
         m.status, m.joined_on,
         (array['walk-in','instagram','referral','google','event'])[1 + (m.idx % 5)],
         (m.idx % 3 <> 0),
         -- One brand-new member has not signed yet, so the waiver gate has a
         -- live subject to refuse.
         case when m.idx = 22 then null
              else (m.joined_on + time '10:00') at time zone tz end
    from _seed_member m;

  -- Member logins for the vertical slice. Only a handful: enough to sign in as
  -- each interesting shape without pretending all 30 use the app. Same local
  -- dev password as the staff accounts.
  --   alena.fabricated  unlimited membership, books with nothing consumed
  --   ivana.sampleton   8-a-month, books against the period allowance
  --   nikola.simulated  class pack, books against a credit
  --   adela.nonexistent no signed waiver, so the §2.1.4 gate refuses her
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at)
  select ('11111111-0000-0000-0003-' || lpad(m.idx::text, 12, '0'))::uuid,
         '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         mem.email, crypt('reform-dev-password', gen_salt('bf')), now(), now()
    from _seed_member m
    join members mem on mem.id = m.id
   where m.idx in (1, 9, 14, 22);

  insert into profiles (id, email, full_name)
  select ('11111111-0000-0000-0003-' || lpad(m.idx::text, 12, '0'))::uuid,
         mem.email, mem.first_name || ' ' || mem.last_name
    from _seed_member m
    join members mem on mem.id = m.id
   where m.idx in (1, 9, 14, 22);

  update members mem
     set user_id = ('11111111-0000-0000-0003-' || lpad(m.idx::text, 12, '0'))::uuid
    from _seed_member m
   where m.id = mem.id and m.idx in (1, 9, 14, 22);

  -- The platform operator, who provisions studios. Synthetic like everything
  -- else here: on a hosted project you insert your own row into
  -- platform_admins by hand, because there is deliberately no screen for it.
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at)
  values ('11111111-0000-0000-0004-000000000001',
          '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'platform@example.com', crypt('reform-dev-password', gen_salt('bf')), now(), now());

  insert into profiles (id, email, full_name)
  values ('11111111-0000-0000-0004-000000000001', 'platform@example.com', 'Platform Operator');

  insert into platform_admins (user_id, email, note)
  values ('11111111-0000-0000-0004-000000000001', 'platform@example.com',
          'Local development operator. Provisions studios at /admin.');

  -- GoTrue scans these columns into non-nullable Go strings, so a hand-inserted
  -- auth.users row with NULLs in them fails every sign-in with "Database error
  -- querying schema" — an error that points at the schema rather than at the
  -- row that caused it. Normalising them to '' is what the real signup path
  -- does; skipping it makes every seeded login useless.
  update auth.users
     set confirmation_token         = coalesce(confirmation_token, ''),
         recovery_token             = coalesce(recovery_token, ''),
         email_change               = coalesce(email_change, ''),
         email_change_token_new     = coalesce(email_change_token_new, ''),
         email_change_token_current = coalesce(email_change_token_current, ''),
         phone_change               = coalesce(phone_change, ''),
         phone_change_token         = coalesce(phone_change_token, ''),
         reauthentication_token     = coalesce(reauthentication_token, ''),
         -- GoTrue scans these into time.Time, not *time.Time, so NULL is fatal
         -- for the same reason.
         created_at                 = coalesce(created_at, now()),
         updated_at                 = coalesce(updated_at, created_at, now())
   where id::text like '11111111-%';

  -- ===========================================================================
  -- 8. Memberships and the payments behind them
  -- ===========================================================================

  -- Recurring plans, current period is the calendar month.
  insert into memberships
    (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
     current_period_start, current_period_end, renews_on, credits_remaining,
     auto_renew, stripe_customer_id, stripe_subscription_id)
  select ('11111111-0000-0000-0001-' || lpad(m.idx::text, 12, '0'))::uuid,
         s, m.id,
         case m.plan when 'unlimited' then pl_unl else pl_eight end,
         case when m.cohort = 'pastdue' then 'past_due'::membership_status
              else 'active'::membership_status end,
         case m.plan when 'unlimited' then 280000 else 180000 end, cur,
         m.joined_on,
         (date_trunc('month', today) )::timestamptz,
         (date_trunc('month', today) + interval '1 month')::timestamptz,
         (date_trunc('month', today) + interval '1 month')::date,
         case m.plan when 'eight' then 8 else null end,
         true,
         'cus_seed_' || m.idx, 'sub_seed_' || m.idx
    from _seed_member m
   where m.plan in ('unlimited','eight');

  -- Packs, bought partway through the member's life, six-month validity.
  insert into memberships
    (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
     expires_on, credits_remaining, auto_renew, stripe_customer_id)
  select ('11111111-0000-0000-0002-' || lpad(m.idx::text, 12, '0'))::uuid,
         s, m.id, pl_pack, 'active', 550000, cur,
         greatest(m.active_from, today - 150),
         greatest(m.active_from, today - 150) + 180,
         10,                                  -- corrected from the ledger below
         false, 'cus_seed_' || m.idx
    from _seed_member m
   where m.plan = 'pack';

  -- Membership invoices. The past_due member's most recent one failed, which
  -- is what put the membership in that status (§7.3).
  insert into payments
    (studio_id, member_id, membership_id, amount_cents, currency, status,
     description, stripe_invoice_id, card_brand, card_last4, paid_at,
     failure_code, failure_message, attempt_count, created_at)
  select s, ms.member_id, ms.id, ms.price_cents, cur,
         case when ms.status = 'past_due' and k = 0 then 'failed'::payment_status
              else 'succeeded'::payment_status end,
         'Monthly membership', 'in_seed_' || m.idx || '_' || k,
         'visa', lpad((1000 + m.idx)::text, 4, '0'),
         case when ms.status = 'past_due' and k = 0 then null
              else (date_trunc('month', today) - make_interval(months => k))::timestamptz end,
         case when ms.status = 'past_due' and k = 0 then 'card_declined' end,
         case when ms.status = 'past_due' and k = 0 then 'Your card was declined.' end,
         case when ms.status = 'past_due' and k = 0 then 3 else 1 end,
         (date_trunc('month', today) - make_interval(months => k))::timestamptz
    from memberships ms
    join _seed_member m on m.id = ms.member_id
    cross join generate_series(0, 2) k
   where m.plan in ('unlimited','eight')
     and (date_trunc('month', today) - make_interval(months => k))::date >= m.joined_on;

  insert into payments
    (studio_id, member_id, membership_id, amount_cents, currency, status,
     description, stripe_payment_intent_id, card_brand, card_last4, paid_at, created_at)
  select s, ms.member_id, ms.id, 550000, cur, 'succeeded',
         '10-Class Pack', 'pi_seed_pack_' || m.idx, 'mastercard',
         lpad((2000 + m.idx)::text, 4, '0'),
         ms.starts_on::timestamptz, ms.starts_on::timestamptz
    from memberships ms
    join _seed_member m on m.id = ms.member_id
   where m.plan = 'pack';

  -- ===========================================================================
  -- 9. Attendance history
  --
  -- Deterministic, not random(): hashtextextended over (member, occurrence)
  -- means an identical database every reset, so a query that misbehaves can be
  -- reproduced rather than re-rolled.
  -- ===========================================================================

  create temp table _seed_attend on commit drop as
  select m.id as member_id, o.id as occurrence_id, o.starts_at, m.idx,
         abs(hashtextextended(m.id::text || o.id::text, 42)) as h,
         false as guaranteed
    from _seed_member m
    -- require_waiver is on, so a member who never signed one could not have
    -- booked: book_class() refuses them at §2.1.4. No waiver, no history.
    join members mem on mem.id = m.id and mem.waiver_signed_at is not null
    join class_occurrences o
      on o.studio_id = s
     and o.starts_at < now()
     and (o.starts_at at time zone tz)::date between m.active_from and m.active_to
   where m.freq > 0
     -- freq classes a week out of the 13 the studio runs
     and (abs(hashtextextended(m.id::text || o.id::text, 42)) % 1000)
         < (m.freq * 1000 / 13);

  -- Respect the room. Capacity is per occurrence, so keep the earliest-hashed
  -- members and drop the overflow rather than seeding an over-capacity class.
  delete from _seed_attend a
   using (
     select member_id, occurrence_id,
            row_number() over (partition by occurrence_id order by h) as rn
       from _seed_attend
   ) ranked
   join class_occurrences o on o.id = ranked.occurrence_id
   where a.member_id = ranked.member_id
     and a.occurrence_id = ranked.occurrence_id
     and ranked.rn > o.capacity;

  -- Guaranteed first visits, placed AFTER the capacity prune and only into
  -- classes that still have a seat, so the prune cannot quietly erase them.
  -- These two cohorts are defined by their visit count, and a one-and-done
  -- member with zero visits is just a lead — the cohort stops meaning anything.
  --
  -- Members who drew nothing from the hash above get exactly one visit:
  --   * one-and-done (freq 0), who then never return
  --   * brand-new members, so "joined, came once, has not rebooked" is a real
  --     shape in the data and not just an absence
  -- Adela signed no waiver, so she has no business having attended anything;
  -- she stays at zero visits, which is its own realistic new-member state.
  insert into _seed_attend (member_id, occurrence_id, starts_at, idx, h, guaranteed)
  select distinct on (m.id)
         m.id, o.id, o.starts_at, m.idx,
         abs(hashtextextended(m.id::text || o.id::text, 42)), true
    from _seed_member m
    join members mem on mem.id = m.id
    join class_occurrences o
      on o.studio_id = s
     and o.starts_at < now()
     -- a fortnight's grace: the one visit lands near joining, not only on
     -- the exact join date, which may have had no class or no free seat
     and (o.starts_at at time zone tz)::date between m.active_from and m.active_to + 14
     and (select count(*) from _seed_attend a2 where a2.occurrence_id = o.id) < o.capacity
   where m.cohort in ('onceonly', 'new')
     and mem.waiver_signed_at is not null
     and not exists (select 1 from _seed_attend a3 where a3.member_id = m.id)
   order by m.id, o.starts_at;

  -- Most turn up. A few cancel late, fewer no-show.
  insert into bookings
    (id, studio_id, occurrence_id, member_id, status, source, payment_source,
     membership_id, booked_at, cancelled_at, is_late_cancel)
  select gen_random_uuid(), s, a.occurrence_id, a.member_id,
         -- a guaranteed visit is the whole point of its cohort, so it is an
         -- attendance; a one-and-done member who no-showed never came at all
         case when a.guaranteed        then 'attended'::booking_status
              when a.h % 100 < 6       then 'no_show'::booking_status
              when a.h % 100 < 14      then 'late_cancelled'::booking_status
              else 'attended'::booking_status end,
         case when a.h % 20 = 0 then 'front_desk'::booking_source
              else 'member'::booking_source end,
         case m.plan when 'unlimited' then 'membership'::payment_source
                     when 'eight'     then 'membership'::payment_source
                     when 'pack'      then 'class_pack'::payment_source
                     else 'drop_in'::payment_source end,
         ms.id,
         a.starts_at - interval '3 days',
         case when not a.guaranteed and a.h % 100 >= 6 and a.h % 100 < 14
              then a.starts_at - interval '2 hours' end,
         (not a.guaranteed and a.h % 100 >= 6 and a.h % 100 < 14)
    from _seed_attend a
    join _seed_member m on m.id = a.member_id
    left join memberships ms
           on ms.member_id = a.member_id
          and ms.plan_id = case m.plan when 'unlimited' then pl_unl
                                       when 'eight'     then pl_eight
                                       when 'pack'      then pl_pack end;

  get diagnostics n_bk = row_count;

  -- An 8-a-month allowance is eight, not eight-ish. Number each member's
  -- bookings in the current period and let the ones past the allowance fall
  -- through to drop-in, which is exactly what book_class() resolution does
  -- when the period credit runs out (§2.2 priority 4).
  create temp table _seed_consume on commit drop as
  select b.id as booking_id, b.member_id, b.membership_id, b.booked_at, m.plan,
         date_trunc('month', b.booked_at at time zone tz)::date as period,
         row_number() over (partition by b.member_id
                            order by b.booked_at, b.id) as rn_all,
         row_number() over (partition by b.member_id,
                                         date_trunc('month', b.booked_at at time zone tz)
                            order by b.booked_at, b.id) as rn_period
    from bookings b
    join _seed_member m on m.id = b.member_id
    join memberships ms on ms.id = b.membership_id
   where b.studio_id = s
     and b.status in ('attended','no_show','late_cancelled')
     and (
          (m.plan = 'pack'  and b.booked_at >= ms.starts_on::timestamptz)
       or  m.plan = 'eight'
     );

  update bookings b
     set payment_source = 'drop_in', membership_id = null
    from _seed_consume c
   where c.booking_id = b.id and c.plan = 'eight' and c.rn_period > 8;

  delete from _seed_consume where plan = 'eight' and rn_period > 8;

  -- Every billing period an 8-a-month member has been through, whether or not
  -- they booked in it, so each one can be granted and then expired.
  create temp table _seed_period on commit drop as
  select c.member_id, c.membership_id, gs.mon::date as period,
         coalesce(u.used, 0) as used
    from (select member_id, membership_id, min(period) as first_period
            from _seed_consume where plan = 'eight' group by 1, 2) c
    cross join lateral
      generate_series(c.first_period, date_trunc('month', today)::date, interval '1 month') gs(mon)
    left join (select member_id, period, count(*) as used
                 from _seed_consume where plan = 'eight' group by 1, 2) u
           on u.member_id = c.member_id and u.period = gs.mon::date;

  insert into check_ins
    (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method,
     checked_in_by)
  select s, b.id, b.member_id, b.occurrence_id,
         o.starts_at - make_interval(mins => (5 + (abs(hashtextextended(b.id::text, 7)) % 20))::int),
         (array['qr','staff','kiosk','self'])[1 + (abs(hashtextextended(b.id::text, 9)) % 4)]::checkin_method,
         case when b.source = 'front_desk' then au_desk end
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = s and b.status = 'attended';

  get diagnostics n_ci = row_count;

  -- booked_count is a denormalised counter that book_class() maintains for
  -- live bookings. History was inserted directly, so bring the counters up to
  -- match the rows that actually exist rather than leaving every past class
  -- reading as empty.
  update class_occurrences o
     set booked_count   = coalesce(c.seats, 0),
         waitlist_count = coalesce(c.waiting, 0)
    from (
      select occurrence_id,
             count(*) filter (where status in ('booked','attended','no_show')) as seats,
             count(*) filter (where status = 'waitlisted')                     as waiting
        from bookings where studio_id = s group by occurrence_id
    ) c
   where o.id = c.occurrence_id and o.studio_id = s;

  -- Drop-in bookings were paid for one at a time.
  insert into payments
    (studio_id, member_id, booking_id, amount_cents, currency, status,
     description, stripe_payment_intent_id, card_brand, card_last4,
     paid_at, created_at)
  select s, b.member_id, b.id, 65000, cur, 'succeeded', 'Drop-in class',
         'pi_seed_drop_' || replace(b.id::text, '-', ''), 'visa', '4242',
         b.booked_at, b.booked_at
    from bookings b
   where b.studio_id = s and b.payment_source = 'drop_in';

  -- ===========================================================================
  -- 10. Credit ledger
  --
  -- §6: the balance is derived from this table, never edited in place, and
  -- balance_after is a running total per member. Built in one pass so the
  -- running total is right by construction.
  --
  -- Recurring allowances do not roll over (Decision 3), so the ledger for an
  -- 8-a-month member starts at the current period boundary. Pack credits
  -- persist, so their ledger starts at purchase. A member never holds both,
  -- which keeps the per-member running total unambiguous.
  -- ===========================================================================

  create temp table _seed_ledger (
    seq bigint generated always as identity,
    member_id uuid, membership_id uuid, delta int, reason credit_reason,
    booking_id uuid, expires_at timestamptz, created_at timestamptz
  ) on commit drop;

  -- Pack grants. A member training weekly for five months does not do it on
  -- one ten-class pack, they buy another when it runs out — so grant a pack
  -- for every ten classes taken, dated just before the block it pays for.
  -- Modelled as repeat grants against the single live pack membership; a
  -- production purchase would open its own memberships row per pack.
  insert into _seed_ledger (member_id, membership_id, delta, reason, expires_at, created_at)
  select c.member_id, c.membership_id, 10, 'purchase',
         (c.booked_at + interval '180 days'), c.booked_at - interval '1 hour'
    from _seed_consume c
   where c.plan = 'pack' and c.rn_all % 10 = 1;

  -- A pack member who is still training has credits in hand: they buy the next
  -- pack when the last one runs out, not at the moment they next book. Without
  -- this, every active pack member sits at exactly zero — grants and
  -- consumption cancel out — and nothing downstream that depends on a member
  -- having credit is exercisable.
  insert into _seed_ledger (member_id, membership_id, delta, reason, expires_at, created_at)
  select c.member_id, c.membership_id, 10, 'purchase',
         max(c.booked_at) + interval '180 days',
         max(c.booked_at) + interval '1 day'
    from _seed_consume c
    join _seed_member m on m.id = c.member_id
   where c.plan = 'pack'
     and m.active_to >= today - 45          -- still coming
   group by c.member_id, c.membership_id;

  -- One allowance grant per billing period the member has lived through.
  insert into _seed_ledger (member_id, membership_id, delta, reason, created_at)
  select pr.member_id, pr.membership_id, 8, 'purchase',
         (pr.period + time '00:00') at time zone tz
    from _seed_period pr;

  -- Decision 3: unused allowance does not roll over. Every closed period is
  -- written off at its boundary, so the running balance never carries a stale
  -- allowance into the next month.
  insert into _seed_ledger (member_id, membership_id, delta, reason, created_at)
  select pr.member_id, pr.membership_id, -(8 - pr.used), 'expiry',
         ((pr.period + interval '1 month') - interval '1 second') at time zone tz
    from _seed_period pr
   where pr.period < date_trunc('month', today)::date
     and pr.used < 8;

  -- Consumption. Late cancels consume too (§3.1, late_cancel_consumes_credit
  -- defaults true); no-shows consume (§3.4, no_show_consumes_credit).
  insert into _seed_ledger (member_id, membership_id, delta, reason, booking_id, created_at)
  select c.member_id, c.membership_id, -1, 'booking', c.booking_id, c.booked_at
    from _seed_consume c;

  insert into credit_ledger
    (studio_id, member_id, membership_id, delta, reason, booking_id,
     balance_after, expires_at, created_at)
  select s, l.member_id, l.membership_id, l.delta, l.reason, l.booking_id,
         sum(l.delta) over (partition by l.member_id
                            order by l.created_at, l.seq
                            rows between unbounded preceding and current row),
         l.expires_at, l.created_at
    from _seed_ledger l;

  -- credits_remaining is a cache of the ledger, so read it back rather than
  -- assuming (§6). No clamp: if this could go negative the seed would be
  -- wrong, and hiding it behind greatest(0, ...) would only bury the fault.
  update memberships ms
     set credits_remaining = (
           select coalesce(sum(cl.delta), 0) from credit_ledger cl
            where cl.studio_id = s and cl.member_id = ms.member_id)
   where ms.studio_id = s
     and ms.credits_remaining is not null;

  -- ===========================================================================
  -- 11. Derived member counters, computed from the rows actually seeded
  -- ===========================================================================

  update members m
     set lifetime_visits = coalesce(v.visits, 0),
         first_visit_at  = v.first_at,
         last_visit_at   = v.last_at
    from (
      select member_id, count(*) as visits,
             min(checked_in_at) as first_at, max(checked_in_at) as last_at
        from check_ins where studio_id = s group by member_id
    ) v
   where m.id = v.member_id;

  -- Decision 5: a streak is consecutive WEEKS with at least one attended
  -- class, in studio-local weeks, and it is broken if they missed last week.
  update members m
     set current_streak = coalesce(st.streak, 0)
    from (
      select run.member_id, count(*) as streak
        from (
          select w.member_id, w.wk,
                 row_number() over (partition by w.member_id order by w.wk desc) as rn,
                 max(w.wk) over (partition by w.member_id) as latest
            from (
              select distinct member_id,
                     date_trunc('week', checked_in_at at time zone tz)::date as wk
                from check_ins where studio_id = s
            ) w
        ) run
       where run.wk = run.latest - (((run.rn - 1) * 7)::int)
         and run.latest >= date_trunc('week', today::timestamp)::date - 7
       group by run.member_id
    ) st
   where m.id = st.member_id;

  -- ===========================================================================
  -- 12. Bookings for the week ahead — through book_class(), not by hand
  --
  -- The seed has no business reimplementing the eligibility gate, capacity
  -- check or credit consumption. Routing future bookings through the real
  -- function also means a seed that survives db reset is evidence the function
  -- still works.
  -- ===========================================================================

  for nxt in
    select m.id as member_id, o.id as occurrence_id
      from _seed_member m
      join class_occurrences o
        on o.studio_id = s
       and o.status = 'scheduled'
       and o.starts_at between now() and now() + interval '7 days'
     where m.cohort in ('regular','eight','pack')
       and (abs(hashtextextended(m.id::text || o.id::text, 99)) % 100) < 18
     order by o.starts_at
  loop
    res := book_class(nxt.occurrence_id, nxt.member_id, 'member');
    if res.failure_reason is null then
      n_future := n_future + 1;
    end if;
  end loop;

  -- book_class() resolves a drop-in but deliberately does not charge for it:
  -- the payments row is the caller's job, and here the seed is the caller.
  insert into payments
    (studio_id, member_id, booking_id, amount_cents, currency, status,
     description, stripe_payment_intent_id, card_brand, card_last4, paid_at, created_at)
  select s, b.member_id, b.id, 65000, cur, 'succeeded', 'Drop-in class',
         'pi_seed_drop_' || replace(b.id::text, '-', ''), 'visa', '4242',
         b.booked_at, b.booked_at
    from bookings b
   where b.studio_id = s and b.payment_source = 'drop_in'
     and not exists (select 1 from payments p where p.booking_id = b.id);

  raise notice 'seed: Reform Collective — % occurrences, % historical bookings, % check-ins, % upcoming bookings',
    n_occ, n_bk, n_ci, n_future;
end $$;
