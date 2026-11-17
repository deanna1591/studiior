-- Step 5: Decision 112 weekly campaigns by audience, Decision 21(b) day tier
-- switch, Decision 30(e) free class on a flex class, refusal sentences,
-- Decision 22(d) phone layout (app only), and housekeeping (template sample
-- context, payment_refunds anon revoke, member_activity reservation wording).
--
-- creates: campaign_member_matches(jsonb, uuid), campaign_audience_for(uuid, uuid), campaign_preview(uuid), campaign_results(uuid), ensure_campaign_defaults(uuid), sweep_weekly_campaigns(uuid, timestamptz), sweep_weekly_campaigns_all(timestamptz), campaign_results_sweep(timestamptz), set_occurrence_day_tier(uuid, text)
-- re-issues: retention_email_context(uuid, text), notification_wanted(uuid, text), book_first_free(uuid, uuid), staff_book_member(uuid, uuid, jsonb, text), template_sample_context(uuid, text, text), member_activity(uuid, date, date)

-- ---- 1. schema -------------------------------------------------------------

-- The do-not-chase switch on the profile (Decision 112 exclusion).
alter table members add column if not exists do_not_chase boolean not null default false;

-- Weekly campaigns, off by default (Settings then Notifications).
alter table studio_settings add column if not exists weekly_campaigns_enabled boolean not null default false;

-- An audience: a filter, an ordered set of templates, a cadence, a schedule,
-- a limit and a priority. First matching audience wins (lowest priority int).
create table if not exists campaign_audiences (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  name          text not null,
  conditions    jsonb not null default '{}'::jsonb,
  template_keys text[] not null,
  cadence_weeks int  not null default 1 check (cadence_weeks between 1 and 8),
  max_weekly    int,                      -- sends in the primary cadence, null = no cap here
  monthly_mode  text not null default 'stop' check (monthly_mode in ('stop','monthly')),
  monthly_cap   int,                      -- monthly sends after the weekly phase (monthly_mode = 'monthly')
  monthly_key   text,                     -- the template for the monthly phase
  send_dow      int  not null check (send_dow between 0 and 6),   -- extract(dow): 0 = Sunday
  send_time     time not null default '10:00',
  priority      int  not null default 100,
  status        text not null default 'active' check (status in ('active','paused')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  is_demo       boolean not null default false
);
create index if not exists campaign_audiences_studio_idx on campaign_audiences (studio_id, priority);

-- One row per member per audience per send: what was sent, and the 7-day result.
create table if not exists campaign_sends (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  audience_id   uuid not null references campaign_audiences(id) on delete cascade,
  member_id     uuid not null references members(id) on delete cascade,
  template_key  text not null,
  week_index    int  not null,            -- 0-based send number for this member in this audience
  notification_id uuid,
  booked_at     timestamptz,
  bought_at     timestamptz,
  created_at    timestamptz not null default now()
);
create unique index if not exists campaign_sends_dedupe
  on campaign_sends (audience_id, member_id, week_index);
create index if not exists campaign_sends_member_idx on campaign_sends (member_id, created_at desc);
create index if not exists campaign_sends_audience_idx on campaign_sends (audience_id, created_at desc);

alter table campaign_audiences enable row level security;
alter table campaign_sends     enable row level security;

drop policy if exists campaign_audiences_manager on campaign_audiences;
create policy campaign_audiences_manager on campaign_audiences
  for all to authenticated
  using (coalesce(is_manager_up(studio_id), false))
  with check (coalesce(is_manager_up(studio_id), false));

drop policy if exists campaign_sends_manager_read on campaign_sends;
create policy campaign_sends_manager_read on campaign_sends
  for select to authenticated
  using (coalesce(is_manager_up(studio_id), false));

grant select, insert, update, delete on campaign_audiences to authenticated, service_role;
grant select on campaign_sends to authenticated, service_role;
grant insert, update on campaign_sends to service_role;

-- ---- 2. the nine platform default templates (80a frame via render) ---------
-- convert_week_2..6, convert_monthly, campaign_try_format, campaign_free_waiting.
-- Platform defaults are plain; Reform's overrides (the approved copy) are the
-- one-off hosted write after the build.
insert into notification_templates (key, subject, text_body, html_body) values
 ('convert_week_2', 'Your free class is still here',
  E'Hi {first_name},\n\nIt has been a couple of weeks since your class. The second class is the one that clicks.\n\n::: card\nname: {offer_plan_name}\ndetail: {offer_detail}\nprice: {offer_price}\nbutton: Keep going | {buy_url}\n:::\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>It has been a couple of weeks since your class. The second class is the one that clicks.</p><p>{studio_name}</p>'),
 ('convert_week_3', 'What a week looks like',
  E'Hi {first_name},\n\nTwo classes a week is the sweet spot. Pick one.\n\n[This week''s classes]({book_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>Two classes a week is the sweet spot. Pick one.</p><p>{studio_name}</p>'),
 ('convert_week_4', 'A note from the studio',
  E'Hi {first_name},\n\nYou do not start strong. You just start.\n\n[Book a class]({book_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>You do not start strong. You just start.</p><p>{studio_name}</p>'),
 ('convert_week_5', 'What it costs, in plain terms',
  E'Hi {first_name},\n\nIf it is the price you are weighing up, here it is.\n\n::: card\nname: {offer_plan_name}\ndetail: {offer_detail}\nprice: {offer_price}\nbutton: Start here | {buy_url}\n:::\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>If it is the price you are weighing up, here it is.</p><p>{studio_name}</p>'),
 ('convert_week_6', 'We will stop filling your inbox',
  E'Hi {first_name},\n\nLast weekly note from us. Book whenever a week opens up.\n\n[Book when you are ready]({book_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>Last weekly note from us. Book whenever a week opens up.</p><p>{studio_name}</p>'),
 ('convert_monthly', 'Still here, {first_name}',
  E'Hi {first_name},\n\nA once-a-month hello. Nothing to do. If this is the month, {offer_plan_name} is the easiest way in.\n\n[See plans]({buy_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>A once-a-month hello. If this is the month, {offer_plan_name} is the easiest way in.</p><p>{studio_name}</p>'),
 ('campaign_try_format', 'Have you tried {untried_class_type} yet?',
  E'Hi {first_name},\n\n{top_class_count} {top_class_type} classes. Try {untried_class_type} next. Your plan covers it.\n\n[Book {untried_class_type}]({book_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>{top_class_count} {top_class_type} classes. Try {untried_class_type} next. Your plan covers it.</p><p>{studio_name}</p>'),
 ('campaign_free_waiting', 'Your free class is waiting, {first_name}',
  E'Hi {first_name},\n\nYour free class is still waiting for you. Pick a time, wear something comfy, bring grip socks.\n\n[Book your free class]({book_url}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>Your free class is still waiting for you. Pick a time, wear something comfy, bring grip socks.</p><p>{studio_name}</p>')
on conflict (key) do nothing;

-- ---- 3. the campaign matcher, preview, results and weekly sweep ------------

-- Pure condition evaluation for one member. Service/internal only.
create or replace function campaign_member_matches(p_conditions jsonb, p_member_id uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare m members%rowtype; v_tz text; v_today date; k text; v jsonb;
        v_types int; v_has_plan boolean; v_free boolean; v_booked boolean;
        v_credits int; v_lastv date; v_joindays int;
begin
  select * into m from members where id = p_member_id;
  if not found then return false; end if;
  select timezone into v_tz from studios where id = m.studio_id;
  v_today := (now() at time zone coalesce(v_tz, 'UTC'))::date;

  for k, v in select * from jsonb_each(coalesce(p_conditions, '{}'::jsonb)) loop
    if k = 'status' then
      if m.status::text <> (v #>> '{}') then return false; end if;

    elsif k = 'has_plan' then
      v_has_plan := exists (select 1 from memberships ms
                             where ms.member_id = m.id and ms.status in ('active','trialing','past_due'));
      if v_has_plan <> (v #>> '{}')::boolean then return false; end if;

    elsif k = 'free_done' then
      v_free := exists (select 1 from bookings b
                         where b.member_id = m.id and b.payment_source = 'comp'
                           and b.status in ('attended','booked'));
      if v_free <> (v #>> '{}')::boolean then return false; end if;

    elsif k = 'never_booked' then
      v_booked := exists (select 1 from bookings b where b.member_id = m.id);
      if (not v_booked) <> (v #>> '{}')::boolean then return false; end if;

    elsif k = 'class_types_min' then
      select count(distinct o.class_type_id) into v_types from check_ins ci
        join class_occurrences o on o.id = ci.occurrence_id where ci.member_id = m.id;
      if v_types < (v #>> '{}')::int then return false; end if;

    elsif k = 'class_types_max' then
      select count(distinct o.class_type_id) into v_types from check_ins ci
        join class_occurrences o on o.id = ci.occurrence_id where ci.member_id = m.id;
      if v_types > (v #>> '{}')::int then return false; end if;

    elsif k = 'joined_min_days' then
      v_joindays := greatest(0, v_today - coalesce(m.joined_on, v_today));
      if v_joindays < (v #>> '{}')::int then return false; end if;

    elsif k = 'last_visit_min_days' then
      v_lastv := coalesce(m.last_visit_at::date, m.first_visit_at::date);
      if v_lastv is null then return false; end if;  -- never visited cannot match a "since last visit" rule
      if (v_today - v_lastv) < (v #>> '{}')::int then return false; end if;

    elsif k = 'credits_left_max' then
      select coalesce(sum(coalesce(ms.credits_remaining, 0)), 0) into v_credits
        from memberships ms where ms.member_id = m.id and ms.status in ('active','trialing','past_due')
          and ms.credits_remaining is not null;
      if v_credits > (v #>> '{}')::int then return false; end if;
    end if;
  end loop;
  return true;
end $$;
revoke execute on function campaign_member_matches(jsonb, uuid) from public, anon, authenticated;
grant  execute on function campaign_member_matches(jsonb, uuid) to service_role;

-- The first matching active audience for a member, with the always-exclusions
-- (marketing consent per Decision 114, do-not-chase, a hard bounce, and any
-- studio email in the last 3 days). Service/internal only.
create or replace function campaign_audience_for(p_studio_id uuid, p_member_id uuid, p_now timestamptz default now())
returns uuid language plpgsql stable security definer set search_path = public as $$
declare m members%rowtype; a campaign_audiences%rowtype;
begin
  select * into m from members where id = p_member_id and studio_id = p_studio_id and deleted_at is null;
  if not found then return null; end if;
  -- Always excluded: no marketing consent, do-not-chase, bounced, or any studio
  -- email in the last 3 days.
  if not (coalesce(m.marketing_opt_in, false) and m.marketing_unsubscribed_at is null) then return null; end if;
  if coalesce(m.do_not_chase, false) then return null; end if;
  if exists (select 1 from notifications n where n.member_id = m.id and n.bounced_at is not null) then return null; end if;
  if exists (select 1 from notifications n where n.member_id = m.id
               and coalesce(n.sent_at, n.created_at) > p_now - interval '3 days') then return null; end if;

  for a in select * from campaign_audiences
             where studio_id = p_studio_id and status = 'active'
             order by priority asc, created_at asc loop
    if campaign_member_matches(a.conditions, p_member_id) then
      return a.id;
    end if;
  end loop;
  return null;
end $$;
revoke execute on function campaign_audience_for(uuid, uuid, timestamptz) from public, anon, authenticated;
grant  execute on function campaign_audience_for(uuid, uuid, timestamptz) to service_role;

-- The live preview: per audience, who lands in it this week (first match, eligible).
create or replace function campaign_preview(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a campaign_audiences%rowtype; v jsonb := '[]'::jsonb; v_members jsonb; v_n int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see campaigns' using errcode = 'PT403';
  end if;
  for a in select * from campaign_audiences where studio_id = p_studio_id order by priority asc, created_at asc loop
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'first_name', x.first_name, 'last_name', x.last_name)
             order by x.first_name), '[]'::jsonb), count(*)
      into v_members, v_n
      from (select m.id, m.first_name, m.last_name
              from members m
             where m.studio_id = p_studio_id and m.deleted_at is null
               and campaign_audience_for(p_studio_id, m.id) = a.id
             limit 200) x;
    v := v || jsonb_build_object('audience_id', a.id, 'name', a.name, 'status', a.status,
                                 'count', v_n, 'members', v_members);
  end loop;
  return v;
end $$;
revoke execute on function campaign_preview(uuid) from public, anon;
grant  execute on function campaign_preview(uuid) to authenticated, service_role;

-- The results: per audience, sends and the 7-day booked/bought counts.
create or replace function campaign_results(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'::jsonb; a campaign_audiences%rowtype; v_sent int; v_booked int; v_bought int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see campaigns' using errcode = 'PT403';
  end if;
  for a in select * from campaign_audiences where studio_id = p_studio_id order by priority asc, created_at asc loop
    select count(*), count(*) filter (where booked_at is not null), count(*) filter (where bought_at is not null)
      into v_sent, v_booked, v_bought
      from campaign_sends where audience_id = a.id and created_at > now() - interval '56 days';
    v := v || jsonb_build_object('audience_id', a.id, 'name', a.name,
               'sent', v_sent, 'booked', v_booked, 'bought', v_bought);
  end loop;
  return v;
end $$;
revoke execute on function campaign_results(uuid) from public, anon;
grant  execute on function campaign_results(uuid) to authenticated, service_role;

-- The three starting audiences, created when a studio turns campaigns on.
create or replace function ensure_campaign_defaults(p_studio_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers manage campaigns' using errcode = 'PT403';
  end if;
  if exists (select 1 from campaign_audiences where studio_id = p_studio_id) then return 0; end if;
  insert into campaign_audiences (studio_id, name, conditions, template_keys, cadence_weeks,
                                  max_weekly, monthly_mode, monthly_cap, monthly_key, send_dow, send_time, priority)
  values
   (p_studio_id, 'Free class done, no plan',
    jsonb_build_object('free_done', true, 'has_plan', false),
    array['convert_week_2','convert_week_3','convert_week_4','convert_week_5','convert_week_6'],
    1, 5, 'monthly', 6, 'convert_monthly', 2, '10:00', 10),
   (p_studio_id, 'Has a plan, tried one class type',
    jsonb_build_object('has_plan', true, 'class_types_min', 1, 'class_types_max', 1),
    array['campaign_try_format'], 2, null, 'stop', null, null, 4, '10:00', 20),
   (p_studio_id, 'Signed up, never booked, over 7 days',
    jsonb_build_object('never_booked', true, 'joined_min_days', 7),
    array['campaign_free_waiting'], 1, 4, 'stop', null, null, 3, '10:00', 30);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function ensure_campaign_defaults(uuid) from public, anon;
grant  execute on function ensure_campaign_defaults(uuid) to authenticated, service_role;

-- The weekly sweep: per studio, in studio time, queueing through queue_notification
-- with per-audience/per-step dedupe. Service only; runs hourly on pg_cron.
create or replace function sweep_weekly_campaigns(p_studio_id uuid, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare st studio_settings%rowtype; s studios%rowtype; v_tz text; v_dow int; v_time time;
        a campaign_audiences%rowtype; r record; n int := 0;
        v_idx int; v_last timestamptz; v_key text; v_payload jsonb; v_nid uuid; v_due boolean;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not coalesce(st.weekly_campaigns_enabled, false) then return 0; end if;
  select * into s from studios where id = p_studio_id;
  v_tz := s.timezone;
  v_dow  := extract(dow from (p_now at time zone v_tz))::int;
  v_time := (p_now at time zone v_tz)::time;

  for a in select * from campaign_audiences
             where studio_id = p_studio_id and status = 'active'
               and send_dow = v_dow order by priority asc loop
    if v_time < a.send_time then continue; end if;         -- not yet this audience's send time today
    for r in select m.id as member_id from members m
               where m.studio_id = p_studio_id and m.deleted_at is null
                 and campaign_audience_for(p_studio_id, m.id, p_now) = a.id loop
      -- how many this audience has already sent this member
      select count(*), max(created_at) into v_idx, v_last
        from campaign_sends where audience_id = a.id and member_id = r.member_id;

      v_due := false; v_key := null;
      if v_idx < coalesce(a.max_weekly, array_length(a.template_keys, 1)) then
        -- weekly phase: cadence_weeks apart
        if v_last is null or v_last <= p_now - make_interval(days => 7 * a.cadence_weeks - 1) then
          v_due := true;
          v_key := a.template_keys[least(v_idx, array_length(a.template_keys, 1) - 1) + 1];
        end if;
      elsif a.monthly_mode = 'monthly'
            and (a.monthly_cap is null or v_idx < coalesce(a.max_weekly, 0) + a.monthly_cap) then
        -- monthly phase
        if v_last is null or v_last <= p_now - interval '27 days' then
          v_due := true;
          v_key := coalesce(a.monthly_key, a.template_keys[array_length(a.template_keys, 1)]);
        end if;
      end if;

      if v_due and v_key is not null then
        v_payload := retention_email_context(r.member_id, 'campaign');
        v_nid := queue_notification(p_studio_id, r.member_id, v_key, v_payload,
                   'campaign:' || a.id::text || ':' || r.member_id::text || ':' || v_idx::text,
                   quiet_hours_shift((p_now at time zone v_tz)::date + a.send_time at time zone v_tz, v_tz));
        if v_nid is not null then
          insert into campaign_sends (studio_id, audience_id, member_id, template_key, week_index, notification_id)
          values (p_studio_id, a.id, r.member_id, v_key, v_idx, v_nid)
          on conflict (audience_id, member_id, week_index) do nothing;
          n := n + 1;
        end if;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function sweep_weekly_campaigns(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function sweep_weekly_campaigns(uuid, timestamptz) to service_role;

create or replace function sweep_weekly_campaigns_all(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_service_context() then
    raise exception 'service only' using errcode = 'PT403';
  end if;
  for r in select studio_id from studio_settings where coalesce(weekly_campaigns_enabled, false) loop
    n := n + coalesce(sweep_weekly_campaigns(r.studio_id, p_now), 0);
  end loop;
  return n;
end $$;
revoke execute on function sweep_weekly_campaigns_all(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_weekly_campaigns_all(timestamptz) to service_role;

-- results backfill: who booked/bought within 7 days of a send (runs in the same cron)
create or replace function campaign_results_sweep(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not is_service_context() then raise exception 'service only' using errcode = 'PT403'; end if;
  update campaign_sends cs set booked_at = (
      select min(b.booked_at) from bookings b
       where b.member_id = cs.member_id and b.booked_at between cs.created_at and cs.created_at + interval '7 days'
         and b.status in ('booked','attended'))
   where cs.booked_at is null and cs.created_at < p_now - interval '10 minutes';
  update campaign_sends cs set bought_at = (
      select min(p.paid_at) from payments p
       where p.member_id = cs.member_id and p.status = 'succeeded'
         and p.paid_at between cs.created_at and cs.created_at + interval '7 days')
   where cs.bought_at is null and cs.created_at < p_now - interval '10 minutes';
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function campaign_results_sweep(timestamptz) from public, anon, authenticated;
grant  execute on function campaign_results_sweep(timestamptz) to service_role;

-- hourly cron: send due audiences and refresh the 7-day results
do $cron$
begin
  if exists (select 1 from cron.job where jobname = 'studiior-weekly-campaigns') then
    perform cron.unschedule('studiior-weekly-campaigns');
  end if;
  perform cron.schedule('studiior-weekly-campaigns', '0 * * * *',
    'select sweep_weekly_campaigns_all(); select campaign_results_sweep();');
end $cron$;

-- ---- 4. Decision 21(b): the day tier switch --------------------------------

-- Where the occurrence's original tier is parked while a day override is on, so
-- a flip back before the cut-off restores it exactly.
alter table class_occurrences add column if not exists day_tier_saved jsonb;

-- The one-off notice to a booked member when the day flips to flex.
insert into notification_templates (key, subject, text_body, html_body) values
 ('day_tier_flex', 'A quick update on your class',
  E'Hi {first_name},\n\n{class_name} on {when} now runs if it reaches {min} bookings by {cutoff}. We will let you know either way before then.\n\n[Manage my booking]({manage_link}){button}\n\n{studio_name}',
  '<p>Hi {first_name},</p><p>{class_name} on {when} now runs if it reaches {min} bookings by {cutoff}. We will let you know either way before then.</p><p>{studio_name}</p>')
on conflict (key) do nothing;

create or replace function set_occurrence_day_tier(p_occurrence_id uuid, p_tier text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; st studio_settings%rowtype; s studios%rowtype;
        v_dir text; v_min int; v_cut timestamptz; v_tz text; v_fmt text; r record; v_restore boolean;
begin
  if p_tier not in ('core','flex') then
    raise exception 'tier must be core or flex' using errcode = 'PT422';
  end if;
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' or o.committed_at is not null or now() >= o.starts_at then
    raise exception 'decided at the cut-off' using errcode = 'PT409';
  end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  select * into s  from studios where id = o.studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- A flip back to the saved original direction restores the saved values.
  v_restore := o.day_tier_saved is not null and p_tier = (o.day_tier_saved ->> 'dir');
  if v_restore then
    update class_occurrences
       set flex = (o.day_tier_saved ->> 'flex')::boolean,
           minimum_bookings = nullif(o.day_tier_saved ->> 'minimum_bookings','')::int,
           guarantee_tier = nullif(o.day_tier_saved ->> 'guarantee_tier','')::guarantee_tier,
           day_tier_saved = null, updated_at = now()
     where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_restored', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('to', p_tier));
    return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', true);
  end if;

  -- Otherwise apply the override, saving the original once.
  select case when g.tier = 'flex' then 'flex' else 'core' end into v_dir
    from occurrence_guarantee_run(p_occurrence_id) g;
  if o.day_tier_saved is null then
    update class_occurrences
       set day_tier_saved = jsonb_build_object('dir', v_dir, 'flex', o.flex,
             'minimum_bookings', o.minimum_bookings, 'guarantee_tier', o.guarantee_tier)
     where id = p_occurrence_id;
  end if;

  if p_tier = 'flex' then
    v_min := coalesce(st.flex_min_bookings, 2);
    update class_occurrences
       set flex = true, minimum_bookings = v_min, guarantee_tier = null, updated_at = now()
     where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_flex', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('minimum_bookings', v_min));
    -- Tell members already booked that it now runs only if it reaches the minimum.
    select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
    for r in select b.member_id from bookings b
               where b.occurrence_id = p_occurrence_id and b.status in ('booked','pending_payment') loop
      perform queue_notification(o.studio_id, r.member_id, 'day_tier_flex',
        jsonb_build_object('class_name', coalesce(o.name, (select name from class_types where id = o.class_type_id)),
          'when', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt),
          'min', v_min::text,
          'cutoff', case when v_cut is not null then fmt_clock(v_cut, v_tz, v_fmt) || ' on ' || to_char(v_cut at time zone v_tz, 'FMDay FMDD FMMonth') else 'the cut-off' end,
          'manage_link', member_portal_url(o.studio_id, '/class/' || o.id),
          'book_url', member_portal_url(o.studio_id, '/book')),
        'day_flex:' || p_occurrence_id::text || ':' || r.member_id::text);
    end loop;
  else
    -- Core today on a flex class: runs regardless of bookings (the always path).
    update class_occurrences
       set guarantee_tier = 'always'::guarantee_tier, updated_at = now()
     where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_core', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('runs_regardless', true));
  end if;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', false);
end $$;
revoke execute on function set_occurrence_day_tier(uuid, text) from public, anon;
grant  execute on function set_occurrence_day_tier(uuid, text) to authenticated, service_role;
-- ---- 5a. notification_wanted: campaign keys by marketing consent; day_tier_flex always-send
CREATE OR REPLACE FUNCTION public.notification_wanted(p_member_id uuid, p_template text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p notification_preferences%rowtype; v_ok boolean;
begin
  if p_template = 'campaign'
     or p_template = any(array['convert_week_2','convert_week_3','convert_week_4','convert_week_5','convert_week_6','convert_monthly','campaign_try_format','campaign_free_waiting']) then
    select (marketing_opt_in and marketing_unsubscribed_at is null) into v_ok
      from members where id = p_member_id;
    return coalesce(v_ok, false);
  end if;

  if left(p_template, 8) = 'convert_' or left(p_template, 5) = 'keep_'
     or left(p_template, 10) = 'retention_' or p_template = 'retention' then
    select sequence_email into v_ok from notification_preferences where member_id = p_member_id;
    return coalesce(v_ok, true);
  end if;

  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    'membership_ended', 'membership_frozen', 'walk_in_welcome', 'day_tier_flex') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    when 'free_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_started' then p.challenge_email
    when 'challenge_ending'  then p.challenge_email
    when 'challenge_completed' then p.challenge_email
    else true
  end;
end $function$;

-- ---- 5b. template_sample_context: method, reference, plan_link, button
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'plans_url', member_portal_url(p_studio_id, '/account/plan'),
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'))
  -- Housekeeping: refund + credited-back tokens so those previews render clean.
  || jsonb_build_object(
    'method', 'GCash', 'reference', 'rfd-sample-0001',
    'plan_link', member_portal_url(p_studio_id, '/account/plan'), 'button', '');
end $function$;

-- ---- 5c. book_first_free: Decision 30(e) free-on-flex flag bypasses the core-only gate
CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid, p_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Decision 100: staff may book a member's free first class (desk-up). Self when
  -- p_member_id is null, which is how the member's own call resolves.
  if p_member_id is not null then
    if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
            or coalesce(current_setting('studiior.late_add', true) = '1', false)) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorised');
    end if;
    select * into v_member from members
     where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  else
    select * into v_member from members
     where studio_id = v_occ.studio_id and user_id = auth.uid();
  end if;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 100 amendment (b): a late add by the class's own instructor is not
  -- desk-up, so use the unguarded eligibility twin under the flag (the picker
  -- already offered free first after its own check).
  if current_setting('studiior.late_add', true) = '1' then
    v_elig := free_first_eligibility_run(v_occ.studio_id, v_member.id, null);
  else
    v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  end if;
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if current_setting('studiior.late_add', true) = '1' then
    if v_occ.ends_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_ended'); end if;
  elsif v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if current_setting('studiior.late_add', true) = '1' then
    null;  -- a late add is inside the cutoff by definition; the flag bypasses it
  elsif v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open'
     and coalesce(current_setting('studiior.free_on_flex', true), '') is distinct from '1' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;

-- ---- 5d. member_activity: staff-released hold distinct from a lapsed one
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- Decision 97 (a): a member merged into this account (staff only). Read from
    -- the member.merged audit row so a past merge shows and the removed email survives.
    select al.created_at as at, 'merged' as kind,
           'Merged ' || coalesce(al.before->>'removed_email', 'an account') || ' into this account' as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'member.merged' and v_is_staff
       and (al.after->>'merged_into')::uuid = p_member_id
    union all
    -- Decision 100: a staff member booked a class for this member (staff only).
    -- Read from the booking.booked_by_staff audit row so the attribution survives.
    select al.created_at as at, 'booked_by_staff' as kind,
           'Booked by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(' with ' || (al.after->>'source'), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'booking.booked_by_staff' and v_is_staff
       and al.entity_id = p_member_id
    union all
    -- Decision 92 (b): removed from a class by staff. From the audit row, so the
    -- class name and the staff first name survive.
    select al.created_at as at, 'removed_by_studio' as kind,
           'Removed from ' || coalesce(al.after->>'class_name', 'a class')
             || ' by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.removed_by_staff' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'reservation_hold'
                when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'Payment pending for ' || coalesce(o.name, 'a class')
                when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'hold_released_staff' else 'hold_released' end)
                when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'Hold released by the studio' else 'Hold released, not paid' end)
                when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from audit_logs al
                        where al.action = 'booking.removed_by_staff' and al.entity_id = b.id)
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'reservation_fee_kept'
                when p.kind = 'reservation_fee' then 'reservation_fee_paid'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'Reservation fee kept'
                when p.kind = 'reservation_fee' then 'Reservation fee paid'
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
    union all
    -- Decision 103(e): reservation credit granted (attended, on-time cancel, or a
    -- lost seat). From member_credits, which the Journey did not read before.
    select mc.created_at, 'reservation_credit_back', 'Fee credited back', null::text,
           null::uuid, mc.amount_cents, mc.currency::text, null::uuid, mc.booking_id, null::uuid
      from member_credits mc
     where mc.member_id = p_member_id and mc.voided_at is null
       and mc.reason in ('reservation_credit', 'reservation_lost_seat')
    union all
    -- Decision 103(e): a released hold re-booked after the payment, or a
    -- reservation covered by credit. From audit_logs (entity = the booking).
    select al.created_at,
           case when al.action = 'reservation.credit_used' then 'reservation_credit_used'
                else 'reservation_restored' end,
           case when al.action = 'reservation.credit_used' then 'Credit used for a reservation'
                else 'Seat restored after payment' end,
           null::text, null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.entity_table = 'bookings'
       and al.action in ('reservation.restored', 'reservation.repaired', 'reservation.credit_used')
       and exists (select 1 from bookings b where b.id = al.entity_id and b.member_id = p_member_id)
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
-- ---- 5e. retention_email_context: top_class_type, top_class_count, untried_class_type
CREATE OR REPLACE FUNCTION public.retention_email_context(p_member_id uuid, p_situation text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; m members%rowtype;
  v_studio uuid; v_tz text; v_today date;
  v_last_class text; v_last_date date; v_instr text;
  v_days int; v_plan text; v_expires date;
  v_offer membership_plans%rowtype; v_offer_name text; v_buy text; v_book text;
  v_offer_price text; v_offer_detail text;
  v_top_type text; v_top_count int; v_untried text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  select * into s from studios where id = v_studio;
  select * into st from studio_settings where studio_id = v_studio;
  select * into m from members where id = p_member_id;
  v_tz := s.timezone;
  v_today := (now() at time zone v_tz)::date;

  select coalesce(ct.name, o.name, 'your class'),
         (o.starts_at at time zone v_tz)::date,
         split_part(coalesce(i.display_name, ''), ' ', 1)
    into v_last_class, v_last_date, v_instr
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    left join class_types ct on ct.id = o.class_type_id
    left join instructors i on i.id = o.instructor_id
   where ci.member_id = p_member_id
   order by ci.checked_in_at desc limit 1;
  if v_last_class is null then
    select coalesce(ct.name, o.name, 'your class'),
           (o.starts_at at time zone v_tz)::date,
           split_part(coalesce(i.display_name, ''), ' ', 1)
      into v_last_class, v_last_date, v_instr
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
     where b.member_id = p_member_id
     order by o.starts_at desc limit 1;
  end if;

  v_days := greatest(0, v_today - coalesce(m.last_visit_at::date, m.first_visit_at::date, v_last_date, v_today));

  select mp.name, coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date)
    into v_plan, v_expires
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = p_member_id
   order by (ms.status = 'active') desc,
            coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date, '-infinity'::date) desc
   limit 1;

  v_book := member_portal_url(v_studio, '/book');

  -- Decision 112 tokens: the member's most-attended class type and its count,
  -- and an active class type they have not tried.
  select ct.name, count(*) into v_top_type, v_top_count
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    join class_types ct on ct.id = o.class_type_id
   where ci.member_id = p_member_id
   group by ct.name order by count(*) desc, ct.name limit 1;
  select ct.name into v_untried
    from class_types ct
   where ct.studio_id = v_studio and ct.status = 'active'
     and not exists (select 1 from check_ins ci
                      join class_occurrences o2 on o2.id = ci.occurrence_id
                      where ci.member_id = p_member_id and o2.class_type_id = ct.id)
   order by ct.name limit 1;
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy := member_portal_url(v_studio, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy := member_portal_url(v_studio, '/account/plan');
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  return jsonb_build_object(
    'first_name', coalesce(nullif(m.first_name, ''), 'there'),
    'last_class', v_last_class,
    'last_class_date', case when v_last_date is not null then to_char(v_last_date, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(v_instr, ''), 'your instructor'),
    'days_since', v_days::text,
    'plan_name', coalesce(v_plan, 'your plan'),
    'expires_on', case when v_expires is not null then to_char(v_expires, 'FMDay FMDD Mon') else '' end,
    'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
    'buy_url', v_buy, 'book_url', v_book, 'studio_name', s.name,
    'top_class_type', coalesce(nullif(v_top_type,''), 'your usual class'),
    'top_class_count', coalesce(v_top_count, 0)::text,
    'untried_class_type', coalesce(nullif(v_untried,''), 'another class'));
end $function$;

-- ---- 5f. staff_book_member: Decision 30(e) free-on-flex switch with audit
CREATE OR REPLACE FUNCTION public.staff_book_member(p_member_id uuid, p_occurrence_id uuid, p_source jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_member members%rowtype;
  v_mgr    boolean;
  v_kind   text;
  v_res    book_class_result;
  v_booking uuid;
  v_conv   jsonb;
  v_pay    jsonb;
  v_staff_first text;
  v_cap    int;
  v_unpaid int;
  v_label  text;
  v_late   boolean;
  v_method text;
  v_tz     text;
  v_fmt    text;
  v_fee    int;
  v_waive  boolean;
  v_deadline timestamptz;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- Decision 100 amendment (b): desk-up adds any member; the class's own
  -- instructor may add a member to THAT class only.
  if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(v_occ.instructor_id), false)) then
    raise exception 'only the desk and up, or the class instructor, book for a member' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  v_mgr := coalesce(is_manager_up(v_occ.studio_id), false) or is_service_context();
  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
    'the studio');
  v_kind := p_source ->> 'kind';
  v_label := p_source ->> 'kind';

  -- Decision 100 amendment (b): a late add books into a class that has
  -- started; after it ends the roster offers no add.
  select timezone into v_tz from studios where id = v_occ.studio_id;
  v_fmt  := v_set.time_format;
  v_late := now() >= v_occ.starts_at;
  if v_late and now() >= v_occ.ends_at then
    return jsonb_build_object('ok', false, 'reason', 'class_ended', 'member_first', v_member.first_name);
  end if;
  v_method := case when coalesce(is_this_instructor(v_occ.instructor_id), false)
                     and not coalesce(is_desk_up(v_occ.studio_id), false)
                   then 'instructor' else 'staff' end;
  if v_late then perform set_config('studiior.late_add', '1', true); end if;

  if v_kind in ('free_first_override','complimentary') and not v_mgr then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_kind = 'plan' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null,
                        (p_source ->> 'membership_id')::uuid);
    v_label := 'a plan';

  elsif v_kind = 'free_first' then
    -- Decision 30(e): a manager may allow this one free class on a flex class.
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      if not v_mgr then
        raise exception 'only owners and managers do this' using errcode = 'PT403';
      end if;
      perform set_config('studiior.free_on_flex', '1', true);
    end if;
    v_conv := book_first_free(p_occurrence_id, p_member_id);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_booking := (v_conv ->> 'booking_id')::uuid;
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (v_occ.studio_id, auth.uid(), 'booking.free_on_flex', 'bookings', v_booking,
              jsonb_build_object('occurrence_id', v_occ.id));
    end if;
    v_label := 'a free first class';

  elsif v_kind = 'free_first_override' then
    -- Book a drop-in, then convert it (overrides the eligibility refusal).
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    if v_res.payment_source is distinct from 'drop_in' then
      return jsonb_build_object('ok', false, 'reason', 'plan_not_covering', 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_conv := convert_booking_to_free_first(v_booking);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a free first class (override)';

  elsif v_kind = 'drop_in_paid' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_pay := record_desk_dropin_paid(v_booking, coalesce(p_source ->> 'method','cash'),
               (p_source ->> 'amount_cents')::int, nullif(p_source ->> 'reference',''));
    if not coalesce((v_pay ->> 'ok')::boolean, true) then
      return jsonb_build_object('ok', false, 'reason', v_pay ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a drop-in, paid at the studio';

  elsif v_kind = 'drop_in_later' then
    -- Enforce the unpaid cap here, because a desk booking bypasses book_class's.
    v_cap := v_set.max_unpaid_bookings;
    select count(*) into v_unpaid from bookings b
     where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
       and b.payment_source = 'drop_in' and b.status in ('booked','pending_payment')
       and not exists (select 1 from payments p where p.booking_id = b.id
                         and p.status in ('succeeded','partially_refunded'));
    if v_cap is not null and v_unpaid >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'pay_first', 'member_first', v_member.first_name);
    end if;
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a drop-in, pay later';

  elsif v_kind = 'complimentary' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk',
                        coalesce(nullif(btrim(coalesce(p_note,'')), ''), 'staff_comp'), 'comp', null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a complimentary seat';

  else
    raise exception 'unknown booking source' using errcode = 'PT400';
  end if;

  -- The plan / drop-in / comp paths return through v_res; carry its refusal.
  if v_kind in ('plan') and v_res.failure_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
  end if;
  if v_kind = 'plan' then v_booking := v_res.booking_id; end if;

  -- Decision 100 amendment (b): a late add is marked attended at once, and the
  -- reservation fee for a free class is waived (staff default on) or due by the
  -- end of the studio day.
  if v_late and v_booking is not null then
    perform record_check_in(v_booking, v_method);
    if v_kind in ('free_first','free_first_override') then
      v_fee   := v_set.free_first_reservation_fee_cents;
      v_waive := case when v_method = 'instructor' then false
                      else coalesce((p_source ->> 'waive_fee')::boolean, true) end;
      if coalesce(v_fee, 0) > 0 and v_member.reservation_fee_waived_at is null then
        if v_waive then
          update bookings set reservation_fee_waived = true where id = v_booking;
        else
          v_deadline := (date_trunc('day', now() at time zone v_tz) + interval '1 day') at time zone v_tz;
          perform queue_notification(v_occ.studio_id, p_member_id, 'free_reservation_due',
            jsonb_build_object(
              'class_name', coalesce(v_occ.name, (select name from class_types where id = v_occ.class_type_id)),
              'day', to_char(v_occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
              'time', fmt_clock(v_occ.starts_at, v_tz, v_fmt),
              'fee', fmt_money(v_fee, (select currency from studios where id = v_occ.studio_id)),
              'from_date', to_char(coalesce(v_set.free_first_reservation_from, now()::date), 'FMDD Mon'),
              'deadline', 'the end of today',
              'pay_url', member_portal_url(v_occ.studio_id, '/class/' || v_occ.id),
              'cancel_url', member_portal_url(v_occ.studio_id, '/class/' || v_occ.id)),
            'free_reservation_due:' || v_booking);
        end if;
      end if;
    end if;
  end if;

  -- The attribution: one audit row (booking.late_add for a late add, else
  -- booking.booked_by_staff, read back by member_activity's Journey arm).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(),
            case when v_late then 'booking.late_add' else 'booking.booked_by_staff' end,
            'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'source', v_label,
                               'occurrence_id', p_occurrence_id, 'booking_id', v_booking,
                               'late', coalesce(v_late, false), 'method', v_method,
                               'note', nullif(btrim(coalesce(p_note,'')), '')));

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'source', v_label,
                            'late', coalesce(v_late, false), 'member_first', v_member.first_name);
end $function$;

-- ---- 6. Housekeeping: revoke anon on payment_refunds (RLS is the boundary; this
--         removes the hosted platform-default grant). ---------------------------
revoke select, insert, update, delete on payment_refunds from anon;

-- ---- 7. anon surface stays EXACTLY THIRTEEN -------------------------------------
do $anon$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface must be exactly 13, got %', v_n;
  end if;
end $anon$;
