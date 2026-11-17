-- Decision 112 weekly campaigns, Decision 21(b) day tier, Decision 30(e) free-on-flex.
-- Space c112. Covers: the audience matcher and its conditions, first-match-by-priority,
-- the four exclusions, the weekly sweep + per-step dedupe + cadence, the three tokens,
-- the day tier switch both ways + the lock + the booked-member notice, the free-on-flex
-- override + its audit, notification_wanted gating by marketing consent, the Journey
-- staff-release distinction, the default audiences, role guards, anon THIRTEEN + RLS.

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin if not coalesce(actual, true) then raise notice 'PASS  %  (got false)', label;
  else raise exception 'BAD  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_raise(label text, want_sqlstate text, stmt text)
returns void language plpgsql as $$
begin begin execute stmt; raise exception 'BAD  %  expected %, no raise', label, want_sqlstate;
  exception when others then
    if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
    else raise exception 'BAD  %  expected %, got %', label, want_sqlstate, sqlstate; end if; end; end $$;

create or replace function c112_as(p_user uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub',p_user::text,'role','authenticated')::text, true); end $$;

-- act as an authenticated (non-superuser) session: sets the jwt AND drops the
-- postgres role so is_service_context() is false and RLS is NOT bypassed.
create or replace function c112_auth(p_user uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub',p_user::text,'role','authenticated')::text, true);
      perform set_config('role', 'authenticated', true); end $$;

do $fix$
declare
  s uuid := 'c1120000-0000-0000-0000-000000000001';
  loc uuid := 'c1120000-0000-0000-0000-0000000000b1';
  ct1 uuid := 'c1120000-0000-0000-0000-0000000000c1';  -- Barre
  ct2 uuid := 'c1120000-0000-0000-0000-0000000000c2';  -- Reformer (flex)
  o_flex uuid := 'c1120000-0000-0000-0000-00000000000f';  -- flex, future (day tier + free-on-flex)
  o_core uuid := 'c1120000-0000-0000-0000-00000000000c';  -- core, future
  o_past uuid := 'c1120000-0000-0000-0000-00000000000a';  -- past Reformer (for check-ins)
  mgr uuid := 'c1120000-0000-0000-0000-0000000000e1'; mgru uuid := 'c1120000-0000-0000-0000-0000000000e2';
  fd uuid := 'c1120000-0000-0000-0000-0000000000e3'; fdu uuid := 'c1120000-0000-0000-0000-0000000000e4';
begin
  insert into studios (id, slug, name, timezone, currency, country) values (s,'c112-studio','C112','Asia/Manila','PHP','PH');
  insert into studio_settings (studio_id, weekly_campaigns_enabled, free_first_class_enabled, free_first_core_only,
         flex_enabled, flex_min_bookings, cancellation_cutoff_minutes)
    values (s, true, true, true, true, 2, 720);
  insert into locations (id, studio_id, name, timezone) values (loc, s, 'Main', 'Asia/Manila');
  insert into class_types (id, studio_id, name, duration_minutes, default_capacity, status) values
    (ct1, s, 'Barre', 50, 20, 'active'),
    (ct2, s, 'Reformer', 50, 20, 'active');
  insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, visibility, status)
    values ('c1120000-0000-0000-0000-0000000000a1', s, 'Pack', 'class_pack', 100000, 'PHP', 10, 'public', 'active');
  insert into imports (id, studio_id, type, filename) values
    ('c1120000-0000-0000-0000-0000000000d1', s, 'attendance', 'c112.csv');
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status, flex, minimum_bookings) values
    (o_flex, s, loc, ct2, 'Reformer', now()+interval '3 days', now()+interval '3 days'+interval '50 min', 20, 'scheduled', true, 2),
    (o_core, s, loc, ct2, 'Reformer', now()+interval '4 days', now()+interval '4 days'+interval '50 min', 20, 'scheduled', false, null),
    (o_past, s, loc, ct2, 'Reformer', now()-interval '2 days', now()-interval '2 days'+interval '50 min', 20, 'scheduled', false, null);
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at) values
    (mgru,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','c112-mgr@example.com', crypt('x',gen_salt('bf')), now(), now(), now()),
    (fdu, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','c112-fd@example.com',  crypt('x',gen_salt('bf')), now(), now(), now());
  insert into profiles (id, email, full_name) values (mgru,'c112-mgr@example.com','Mgr'),(fdu,'c112-fd@example.com','FD');
  insert into studio_staff (id, studio_id, user_id, role, status, email) values
    (mgr, s, mgru, 'manager','active','c112-mgr@example.com'),
    (fd,  s, fdu,  'front_desk','active','c112-fd@example.com');
end $fix$;

-- member maker: tag, status, marketing on/off, joined_days_ago, with_plan
create or replace function c112_member(p_tag text, p_status text default 'lead',
  p_marketing boolean default true, p_joined_days int default 0, p_with_plan boolean default false)
returns uuid language plpgsql as $$
declare s uuid := 'c1120000-0000-0000-0000-000000000001'; u uuid := gen_random_uuid(); m uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated', p_tag||'@c112.example.com', crypt('x',gen_salt('bf')), now(), now(), now());
  insert into profiles (id, email, full_name) values (u, p_tag||'@c112.example.com', p_tag);
  insert into members (id, studio_id, user_id, first_name, last_name, email, status, marketing_opt_in, joined_on)
    values (m, s, u, p_tag, 'M', p_tag||'@c112.example.com', p_status::member_status, p_marketing, (now() at time zone 'Asia/Manila')::date - p_joined_days);
  if p_with_plan then
    insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, auto_renew, starts_on)
      values (s, m, 'c1120000-0000-0000-0000-0000000000a1', 'active', 0, 'PHP', 5, false, current_date);
  end if;
  return m;
end $$;

-- ===================== Part 1: the audience matcher =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        ct2 uuid := 'c1120000-0000-0000-0000-0000000000c2';
        o_past uuid := 'c1120000-0000-0000-0000-00000000000a';
        m_free uuid; m_plan uuid; m_newbie uuid; m_tried uuid; bk uuid;
begin
  -- free class done, no plan (first default audience)
  m_free := c112_member('free-noplan');
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
    values (gen_random_uuid(), s, o_past, m_free, 'attended','member','comp', now()-interval '5 days');
  perform expect_true('1 free-done-no-plan matches {free_done,has_plan:false}',
    campaign_member_matches(jsonb_build_object('free_done', true, 'has_plan', false), m_free));

  -- has a plan -> does NOT match free_done/no-plan
  m_plan := c112_member('has-plan', 'active', true, 0, true);
  perform expect_false('1 plan member fails has_plan:false',
    campaign_member_matches(jsonb_build_object('has_plan', false), m_plan));
  perform expect_true('1 plan member matches has_plan:true',
    campaign_member_matches(jsonb_build_object('has_plan', true), m_plan));

  -- signed up, never booked, over 7 days
  m_newbie := c112_member('newbie', 'lead', true, 10);
  perform expect_true('1 never-booked 10d matches {never_booked,joined_min_days:7}',
    campaign_member_matches(jsonb_build_object('never_booked', true, 'joined_min_days', 7), m_newbie));
  perform expect_false('1 joined 10d fails joined_min_days:14',
    campaign_member_matches(jsonb_build_object('joined_min_days', 14), m_newbie));
  -- a member with a booking fails never_booked
  perform expect_false('1 booked member fails never_booked',
    campaign_member_matches(jsonb_build_object('never_booked', true), m_free));

  -- tried exactly one class type (class_types_min/max)
  m_tried := c112_member('tried-one', 'active', true, 0, true);
  insert into check_ins (studio_id, occurrence_id, member_id, checked_in_at, method, import_id)
    values (s, o_past, m_tried, now()-interval '2 days', 'self', 'c1120000-0000-0000-0000-0000000000d1');
  perform expect_true('1 tried-one matches class_types_min:1,max:1',
    campaign_member_matches(jsonb_build_object('class_types_min', 1, 'class_types_max', 1), m_tried));
  perform expect_false('1 tried-one fails class_types_min:2',
    campaign_member_matches(jsonb_build_object('class_types_min', 2), m_tried));
end $t$;

-- ===================== Part 2: first-match by priority + exclusions =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        a_lo uuid := gen_random_uuid(); a_hi uuid := gen_random_uuid();
        m uuid; m_off uuid; m_dnc uuid; m_bounce uuid; m_recent uuid;
begin
  -- two active audiences both matching a lead; lower priority number wins
  insert into campaign_audiences (id, studio_id, name, conditions, template_keys, send_dow, priority, status) values
    (a_lo, s, 'Low pri', jsonb_build_object('status','lead'), array['convert_week_2'], 0, 5,  'active'),
    (a_hi, s, 'High pri',jsonb_build_object('status','lead'), array['convert_week_2'], 0, 50, 'active');
  m := c112_member('fm-lead');
  perform expect_text('2 first match is the lower priority audience',
    (campaign_audience_for(s, m))::text, a_lo::text);

  -- marketing off -> excluded
  m_off := c112_member('ex-off', 'lead', false);
  perform expect_text('2 marketing off -> null', (campaign_audience_for(s, m_off))::text, null);

  -- do-not-chase -> excluded
  m_dnc := c112_member('ex-dnc');
  update members set do_not_chase = true where id = m_dnc;
  perform expect_text('2 do-not-chase -> null', (campaign_audience_for(s, m_dnc))::text, null);

  -- a bounce on file -> excluded
  m_bounce := c112_member('ex-bounce');
  insert into notifications (studio_id, recipient_type, member_id, template_key, channel, status, dedupe_key, scheduled_for, bounced_at, created_at)
    values (s, 'member', m_bounce, 'booking_confirmed', 'email', 'sent', 'c112-bounce', now()-interval '10 days', now()-interval '10 days', now()-interval '10 days');
  perform expect_text('2 bounced -> null', (campaign_audience_for(s, m_bounce))::text, null);

  -- an email in the last 3 days -> excluded
  m_recent := c112_member('ex-recent');
  insert into notifications (studio_id, recipient_type, member_id, template_key, channel, status, dedupe_key, scheduled_for, sent_at, created_at)
    values (s, 'member', m_recent, 'booking_confirmed', 'email', 'sent', 'c112-recent', now()-interval '4 days', now()-interval '1 day', now()-interval '1 day');
  perform expect_text('2 recent email -> null (3-day quiet)', (campaign_audience_for(s, m_recent))::text, null);
  -- an email 4 days ago does NOT exclude
  update notifications set sent_at = now()-interval '4 days', created_at = now()-interval '4 days' where member_id = m_recent;
  perform expect_text('2 email 4d ago -> matches again', (campaign_audience_for(s, m_recent))::text, a_lo::text);

  -- pause the audiences so they do not interfere with the sweep part
  update campaign_audiences set status = 'paused' where id in (a_lo, a_hi);
end $t$;

-- ===================== Part 3: the weekly sweep + dedupe + cadence =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        a uuid := gen_random_uuid(); m uuid; dow int; n int;
begin
  dow := extract(dow from (now() at time zone 'Asia/Manila'))::int;
  -- an audience whose send day is today, send time already passed
  insert into campaign_audiences (id, studio_id, name, conditions, template_keys, cadence_weeks,
                                  max_weekly, send_dow, send_time, priority, status)
    values (a, s, 'Sweep test', jsonb_build_object('never_booked', true, 'joined_min_days', 7),
            array['campaign_free_waiting','convert_week_2'], 1, 2, dow, time '00:00', 1, 'active');
  m := c112_member('sweep-me', 'lead', true, 10);

  n := sweep_weekly_campaigns(s, now());
  perform expect_num('3 first sweep queues one', (select count(*) from campaign_sends where audience_id=a and member_id=m), 1);
  perform expect_num('3 week_index 0 first', (select week_index from campaign_sends where audience_id=a and member_id=m), 0);
  perform expect_text('3 first template is step 1', (select template_key from campaign_sends where audience_id=a and member_id=m limit 1), 'campaign_free_waiting');
  perform expect_num('3 one campaign notification queued',
    (select count(*) from notifications where member_id=m and template_key='campaign_free_waiting'), 1);

  -- a second sweep the same minute -> no second send (cadence: last send just now)
  n := sweep_weekly_campaigns(s, now());
  perform expect_num('3 second sweep no duplicate', (select count(*) from campaign_sends where audience_id=a and member_id=m), 1);

  -- a sweep a week later -> the next step (week_index 1)
  n := sweep_weekly_campaigns(s, now() + interval '7 days');
  perform expect_num('3 week later sends step 2', (select count(*) from campaign_sends where audience_id=a and member_id=m), 2);
  perform expect_text('3 step 2 template', (select template_key from campaign_sends where audience_id=a and member_id=m and week_index=1), 'convert_week_2');

  -- max_weekly 2 reached, monthly_mode 'stop' -> no more
  n := sweep_weekly_campaigns(s, now() + interval '14 days');
  perform expect_num('3 stop after max_weekly', (select count(*) from campaign_sends where audience_id=a and member_id=m), 2);

  -- a member who bought a plan mid-run drops out of the no-plan-style audience by condition
  -- (here: give them a booking so never_booked fails)
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
    values (gen_random_uuid(), s, 'c1120000-0000-0000-0000-00000000000a', m, 'attended','member','drop_in', now());
  perform expect_text('3 booked member no longer in audience', (campaign_audience_for(s, m))::text, null);

  update campaign_audiences set status = 'paused' where id = a;
end $t$;

-- ===================== Part 4: the three tokens =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        ct2 uuid := 'c1120000-0000-0000-0000-0000000000c2';
        o_past uuid := 'c1120000-0000-0000-0000-00000000000a';
        m uuid; ctx jsonb;
begin
  m := c112_member('tokens', 'active', true, 0, true);
  insert into check_ins (studio_id, occurrence_id, member_id, checked_in_at, method, import_id) values
    (s, o_past, m, now()-interval '3 days', 'self', 'c1120000-0000-0000-0000-0000000000d1'),
    (s, o_past, m, now()-interval '1 day',  'self', 'c1120000-0000-0000-0000-0000000000d1');
  ctx := retention_email_context(m, 'campaign');
  perform expect_text('4 top_class_type is Reformer', ctx->>'top_class_type', 'Reformer');
  perform expect_text('4 top_class_count is 2', ctx->>'top_class_count', '2');
  perform expect_text('4 untried_class_type is Barre', ctx->>'untried_class_type', 'Barre');
end $t$;

-- ===================== Part 5: the day tier switch =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        o_flex uuid := 'c1120000-0000-0000-0000-00000000000f';
        mgru uuid := 'c1120000-0000-0000-0000-0000000000e2'; fdu uuid := 'c1120000-0000-0000-0000-0000000000e4';
        m uuid; res jsonb; v_tier guarantee_tier;
begin
  -- a booked member so the flex notice has somebody to reach
  m := c112_member('tier-booked', 'active', true, 0, true);
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
    values (gen_random_uuid(), s, o_flex, m, 'booked','member','drop_in', now());

  -- front desk cannot
  perform c112_as(fdu);
  perform expect_raise('5 front desk PT403', 'PT403',
    format('select set_occurrence_day_tier(%L, %L)', o_flex, 'flex'));
  reset role;

  -- manager flips the flex class to CORE (always)
  perform c112_as(mgru);
  res := set_occurrence_day_tier(o_flex, 'core');
  perform expect_true('5 core flip ok', (res->>'ok')::boolean);
  select guarantee_tier into v_tier from class_occurrences where id = o_flex;
  perform expect_text('5 core flip sets always', v_tier::text, 'always');
  perform expect_num('5 core audit row', (select count(*) from audit_logs where action='occurrence.day_tier_core' and entity_id=o_flex), 1);

  -- flip back to flex (restores: flex true, min 2, guarantee_tier null) and notifies the booked member
  res := set_occurrence_day_tier(o_flex, 'flex');
  perform expect_true('5 flex restore ok+restored', (res->>'restored')::boolean);
  perform expect_true('5 flex restored flag', (select flex from class_occurrences where id=o_flex));
  perform expect_num('5 flex restored min', (select minimum_bookings from class_occurrences where id=o_flex), 2);
  perform expect_text('5 day_tier_saved cleared', (select day_tier_saved::text from class_occurrences where id=o_flex), null);
  reset role;

  -- now flip a genuinely-core class to flex and confirm the booked-member notice goes out
  perform c112_as(mgru);
  res := set_occurrence_day_tier('c1120000-0000-0000-0000-00000000000c', 'flex');
  reset role;
  perform expect_true('5 core->flex sets flex', (select flex from class_occurrences where id='c1120000-0000-0000-0000-00000000000c'));
  perform expect_num('5 core->flex min is studio flex min', (select minimum_bookings from class_occurrences where id='c1120000-0000-0000-0000-00000000000c'), 2);

  -- a booked member on o_core gets the day_tier_flex notice
  declare m2 uuid; begin
    m2 := c112_member('tier-notice', 'active', true, 0, true);
    insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
      values (gen_random_uuid(), s, o_flex, m2, 'booked','member','drop_in', now());
    perform c112_as(mgru);
    perform set_occurrence_day_tier(o_flex, 'core');   -- first a change away
    perform set_occurrence_day_tier(o_flex, 'core');   -- idempotent restore-dir check skipped
    reset role;
  end;
end $t$;

-- the booked-member notice on a core->flex flip (clean occurrence + booked member)
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        mgru uuid := 'c1120000-0000-0000-0000-0000000000e2';
        o uuid := gen_random_uuid(); m uuid;
begin
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status, flex)
    values (o, s, 'c1120000-0000-0000-0000-0000000000b1', 'c1120000-0000-0000-0000-0000000000c2',
            'Reformer', now()+interval '5 days', now()+interval '5 days'+interval '50 min', 20, 'scheduled', false);
  m := c112_member('flex-notice', 'active', true, 0, true);
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
    values (gen_random_uuid(), s, o, m, 'booked','member','drop_in', now());
  perform c112_as(mgru);
  perform set_occurrence_day_tier(o, 'flex');
  reset role;
  perform expect_num('5 core->flex notifies the booked member',
    (select count(*) from notifications where member_id=m and template_key='day_tier_flex'), 1);
end $t$;

-- the lock: a committed/started occurrence cannot be flipped
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        mgru uuid := 'c1120000-0000-0000-0000-0000000000e2';
        o_c uuid := gen_random_uuid(); o_s uuid := gen_random_uuid();
begin
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status, flex, committed_at) values
    (o_c, s, 'c1120000-0000-0000-0000-0000000000b1', 'c1120000-0000-0000-0000-0000000000c2','Reformer', now()+interval '2 days', now()+interval '2 days'+interval '50 min', 20, 'scheduled', true, now());
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status, flex) values
    (o_s, s, 'c1120000-0000-0000-0000-0000000000b1', 'c1120000-0000-0000-0000-0000000000c2','Reformer', now()-interval '1 hour', now()-interval '10 min', 20, 'scheduled', true);
  perform c112_as(mgru);
  perform expect_raise('5 committed locked PT409', 'PT409', format('select set_occurrence_day_tier(%L, %L)', o_c, 'core'));
  perform expect_raise('5 started locked PT409',   'PT409', format('select set_occurrence_day_tier(%L, %L)', o_s, 'core'));
  perform expect_raise('5 bad tier PT422', 'PT422', format('select set_occurrence_day_tier(%L, %L)', o_c, 'maybe'));
  reset role;
end $t$;

-- ===================== Part 6: free-on-flex override =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        mgru uuid := 'c1120000-0000-0000-0000-0000000000e2'; fdu uuid := 'c1120000-0000-0000-0000-0000000000e4';
        o uuid := gen_random_uuid(); m uuid; res jsonb;
begin
  -- a fresh flex Reformer; free_first_core_only is on, so free-first is normally refused
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status, flex, minimum_bookings)
    values (o, s, 'c1120000-0000-0000-0000-0000000000b1', 'c1120000-0000-0000-0000-0000000000c2',
            'Reformer', now()+interval '6 days', now()+interval '6 days'+interval '50 min', 20, 'scheduled', true, 2);

  -- WITHOUT the override: refused (core-only blocks a free class on a flex class)
  m := c112_member('flex-free-no');
  perform c112_as(mgru);
  res := staff_book_member(m, o, jsonb_build_object('kind','free_first'), null);
  perform expect_false('6 free on flex refused without override', (res->>'ok')::boolean);

  -- WITH the override: booked free (comp booking + host-null guest pass) + audit
  m := c112_member('flex-free-yes');
  res := staff_book_member(m, o, jsonb_build_object('kind','free_first','allow_free_on_flex', true), null);
  perform expect_true('6 free on flex ok with override', (res->>'ok')::boolean);
  perform expect_text('6 free-on-flex books a comp seat',
    (select payment_source::text from bookings where id=(res->>'booking_id')::uuid), 'comp');
  perform expect_num('6 free-on-flex audit row',
    (select count(*) from audit_logs where action='booking.free_on_flex' and entity_id=(res->>'booking_id')::uuid), 1);
  reset role;

  -- front desk cannot use the override (authenticated role so is_service_context is false)
  m := c112_member('flex-free-fd');
  perform c112_auth(fdu);
  perform expect_raise('6 front desk override PT403', 'PT403',
    format('select staff_book_member(%L, %L, %L::jsonb, null)', m, o, '{"kind":"free_first","allow_free_on_flex":true}'));
end $t$;

-- ===================== Part 7: notification_wanted gating =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001'; m_on uuid; m_off uuid;
begin
  m_on  := c112_member('nw-on',  'lead', true);
  m_off := c112_member('nw-off', 'lead', false);
  perform expect_true ('7 campaign wanted with consent', notification_wanted(m_on,  'campaign_free_waiting'));
  perform expect_false('7 campaign not wanted without consent', notification_wanted(m_off, 'campaign_free_waiting'));
  -- a day_tier_flex notice always goes (it is about a booking)
  perform expect_true ('7 day_tier_flex always sent', notification_wanted(m_off, 'day_tier_flex'));
end $t$;

-- ===================== Part 8: the Journey staff-release distinction =====================
do $t$
declare s uuid := 'c1120000-0000-0000-0000-000000000001';
        o_past uuid := 'c1120000-0000-0000-0000-00000000000a';
        m uuid; bk_staff uuid := gen_random_uuid(); bk_lapse uuid := gen_random_uuid();
begin
  m := c112_member('journey');
  -- an unpaid reservation hold the STUDIO released (cancelled comp, no guest pass, no payment, with the staff audit)
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, cancelled_at)
    values (bk_staff, s, o_past, m, 'cancelled','member','comp', now()-interval '2 days', now()-interval '1 day');
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (s, null, 'reservation.hold_released_by_staff', 'bookings', bk_staff, '{}'::jsonb);
  -- a lapsed hold (same shape, no staff audit)
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, cancelled_at)
    values (bk_lapse, s, o_past, m, 'cancelled','member','comp', now()-interval '2 days', now()-interval '1 day');

  perform expect_num('8 staff-released reads hold_released_staff',
    (select count(*) from member_activity(m, current_date - 10, current_date + 1) where kind='hold_released_staff'), 1);
  perform expect_num('8 lapsed reads hold_released',
    (select count(*) from member_activity(m, current_date - 10, current_date + 1) where kind='hold_released'), 1);
end $t$;

-- ===================== Part 9: defaults + RLS + role guard + anon THIRTEEN =====================
do $t$
declare s2 uuid := 'c1120000-0000-0000-0000-000000000002'; mgru uuid := 'c1120000-0000-0000-0000-0000000000e2';
        n int;
begin
  -- a second studio with no audiences yet; ensure_campaign_defaults creates three
  insert into studios (id, slug, name, timezone, currency, country) values (s2,'c112b','C112B','Asia/Manila','PHP','PH');
  insert into studio_settings (studio_id) values (s2);
  insert into studio_staff (id, studio_id, user_id, role, status, email)
    values (gen_random_uuid(), s2, mgru, 'owner','active','c112-mgr@example.com');
  perform c112_as(mgru);
  n := ensure_campaign_defaults(s2);
  perform expect_num('9 three defaults created', n, 3);
  perform expect_num('9 second call creates nothing', ensure_campaign_defaults(s2), 0);
  perform expect_num('9 preview returns three audiences', jsonb_array_length(campaign_preview(s2)), 3);
  reset role;

  -- front desk is refused the manager-up readers/writers (authenticated role so
  -- is_service_context is false and RLS applies). Scoped local to this block.
  perform c112_auth('c1120000-0000-0000-0000-0000000000e4');
  perform expect_raise('9 front desk preview PT403', 'PT403', format('select campaign_preview(%L)', 'c1120000-0000-0000-0000-000000000001'));
  perform expect_raise('9 front desk defaults PT403', 'PT403', format('select ensure_campaign_defaults(%L)', 'c1120000-0000-0000-0000-000000000001'));
  -- RLS: front desk reads no campaign_audiences rows (manager-up)
  perform expect_num('9 front desk sees no audiences',
    (select count(*) from campaign_audiences where studio_id='c1120000-0000-0000-0000-000000000001'), 0);
  -- manager (authenticated) reads their own studio's audiences through RLS
  perform c112_auth(mgru);
  perform expect_true('9 manager reads audiences',
    (select count(*) from campaign_audiences where studio_id=s2) >= 3);
end $t$;

-- anon surface EXACTLY THIRTEEN + payment_refunds revoked from anon + inbox table
do $t$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%' and p.proname not like 'c112_%'
     and p.proname not like 'd111_%';
  perform expect_num('9 anon surface THIRTEEN', n, 13);
  perform expect_false('9 payment_refunds not anon-selectable',
    has_table_privilege('anon','payment_refunds','select'));
end $t$;

select 'campaigns_daytier_test PASS' as result;
