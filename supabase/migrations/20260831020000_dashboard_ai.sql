-- =============================================================================
-- Migration 092 — the AI layer: prose about numbers it is not allowed to make
--
-- THE HARD BOUNDARY. Migration 091 computes every figure. This file sends
-- those figures to Claude and stores the sentence that comes back. It never
-- computes one, and the check that this is true is mechanical rather than a
-- promise: dashboard_facts() publishes the exact set of numbers the model may
-- use, and narrative_offending_number() refuses any answer containing a number
-- outside it. A narrative that says 12 where the card says 14 is REJECTED, not
-- displayed with a caveat.
--
-- THE FALLBACK IS THE DEFAULT, NOT THE ERROR PATH. Every narrative has a
-- deterministic sentence composed in SQL and stored beside it. The model's
-- version replaces it only after passing verification. So a studio whose key
-- is unset, whose call timed out, or whose answer was refused sees a complete
-- dashboard with plainer prose — and never a spinner, a gap, or a wrong
-- number. Anthropic being down is a change of voice, not an outage.
--
-- Cached per studio per day, generated on a cron. This does not run on page
-- load: a dashboard that calls an API to render is a dashboard that is slow
-- every morning and broken on the morning it matters.
-- =============================================================================

create table dashboard_ai_config (
  key   text primary key,
  value text not null,
  note  text
);
alter table dashboard_ai_config enable row level security;
create policy dash_ai_config_platform on dashboard_ai_config
  for all using (is_platform_admin()) with check (is_platform_admin());
grant select, insert, update, delete on dashboard_ai_config to authenticated;
grant all on dashboard_ai_config to service_role;

insert into dashboard_ai_config (key, value, note) values
  ('enabled',        '1',       'Off makes every narrative the deterministic one. Nothing else changes.'),
  ('model',          'claude-sonnet-5', 'A row rather than a literal so the model can move without a migration.'),
  ('prompt_version', 'v1',      'Stored on every narrative, so a wrong sentence can be traced to the prompt that produced it.'),
  ('max_tokens',     '400',     'These are two or three sentences. A larger budget buys a longer answer, not a better one.'),
  ('timeout_ms',     '20000',   'Generous: this is a cron, and nobody is waiting on it.'),
  ('api_url',        'https://api.anthropic.com/v1/messages', null),
  ('api_version',    '2023-06-01', null);

create or replace function dashboard_ai_setting(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from dashboard_ai_config where key = p_key
$$;

/**
 * The API key, from Vault, falling back to a database setting. Both are set
 * out of band at deploy time and neither is in the repo — the same shape as
 * notification_api_key(), for the same reason.
 *
 * Null when unconfigured, which is an ordinary state: a fresh local stack has
 * none. The caller must handle it rather than raise, or one unset key takes
 * down the cron for every studio.
 */
create or replace function anthropic_api_key() returns text
language plpgsql stable security definer set search_path = public, vault as $$
declare v text;
begin
  begin
    select decrypted_secret into v from vault.decrypted_secrets
     where name = 'ANTHROPIC_API_KEY' limit 1;
  exception when others then
    v := null;
  end;
  return coalesce(nullif(v, ''), nullif(current_setting('app.anthropic_api_key', true), ''));
end $$;

-- -----------------------------------------------------------------------------
-- The cache
--
-- One row per studio per day per kind. `facts` is exactly what was sent,
-- `response_body` exactly what came back, and `prompt_version` and `model`
-- name what produced it — so a narrative somebody disagrees with can be traced
-- rather than argued about.
--
-- `fallback` is written at queue time, BEFORE the call. That is what makes the
-- degradation real: the row is useful the moment it exists, and everything the
-- API does afterwards is an improvement on something already correct.
-- -----------------------------------------------------------------------------
create table dashboard_narratives (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  for_date       date not null,
  kind           text not null check (kind in ('revenue','lead','attendance','draft')),
  -- 'draft' is per member; the other three are per studio. A draft has to
  -- name the person to be worth having, so it cannot be one row a day.
  subject_id     uuid,
  status         text not null default 'pending'
                 check (status in ('pending','ready','failed','rejected','skipped')),
  fallback       text not null,
  body           text,
  lead_insight_id uuid references ai_insights on delete set null,
  facts          jsonb not null default '{}',
  model          text,
  prompt_version text,
  net_request_id bigint,
  request_body   jsonb,
  response_body  jsonb,
  error          text,
  queued_at      timestamptz not null default now(),
  completed_at   timestamptz,
  created_at     timestamptz not null default now()
);
create unique index dashboard_narratives_one_per_day on dashboard_narratives
  (studio_id, for_date, kind, coalesce(subject_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index on dashboard_narratives (studio_id, for_date desc);
create index on dashboard_narratives (studio_id, kind, subject_id) where subject_id is not null;
create index on dashboard_narratives (status) where status = 'pending';

alter table dashboard_narratives enable row level security;
-- Manager-up read only. The narrative describes revenue and churn, which
-- Permissions §12 note 21 keeps away from instructors and front desk, and it
-- is written by the backend — no client role writes it.
create policy dash_narratives_read on dashboard_narratives
  for select using (is_manager_up(studio_id));
grant select on dashboard_narratives to authenticated;
grant all on dashboard_narratives to service_role;

-- -----------------------------------------------------------------------------
-- THE VERIFIER
--
-- Every number-shaped token in the prose, normalised, checked against the set
-- the facts published. Returns the first token that is not in it, or null when
-- the sentence is clean.
--
-- Strict on purpose. A false rejection costs the deterministic sentence, which
-- is correct and already on the screen. A false acceptance puts a number on a
-- studio's dashboard that nothing computed — and that is the failure this
-- whole layer is arranged to make impossible.
-- -----------------------------------------------------------------------------
create or replace function narrative_numbers(p_text text) returns text[]
language sql immutable as $$
  select coalesce(
    array_agg(distinct replace(m[1], ',', '')),
    array[]::text[])
    from regexp_matches(
      -- A CLOCK TIME IS ONE FIGURE. Splitting "19:00" on the colon yields 19
      -- and 00, and 00 is in no fact set anywhere, so every sentence naming an
      -- hour would be refused for a number nobody wrote. Collapse it first and
      -- the allowed set carries "1900".
      regexp_replace(coalesce(p_text, ''), '([0-9]{1,2}):([0-9]{2})', '\1\2', 'g'),
      -- A thousands separator is a comma followed by EXACTLY three digits.
      -- The looser [0-9,\s]* swallowed the gap between two numbers and glued
      -- "19:00, 38" into the single token 190038 — a figure nobody wrote,
      -- refusing a sentence that was fine.
      '([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)', 'g') m
$$;

create or replace function narrative_offending_number(p_text text, p_allowed text[])
returns text
language sql immutable as $$
  select n from unnest(narrative_numbers(p_text)) n
   -- Compared as numbers, not as strings: a model that writes 42900.0 against
   -- an allowed 42900 has written the same figure. (String trimming looked
   -- like it would do this and quietly turned 42900 into 429.)
   where not exists (
     select 1 from unnest(p_allowed) a
      where a ~ '^[0-9]+(\.[0-9]+)?$'
        and n ~ '^[0-9]+(\.[0-9]+)?$'
        and a::numeric = n::numeric)
   limit 1
$$;

comment on function narrative_offending_number(text, text[]) is
  'The first number in the prose that the facts did not contain, or null. This '
  'is the mechanical form of "the AI never computes anything" — a narrative '
  'that fails it is discarded and the deterministic sentence stands.';

-- -----------------------------------------------------------------------------
-- THE FACTS
--
-- Everything the model is given, and — by construction — everything it is
-- allowed to say. `allowed` is the exact set of numeric tokens that may appear
-- in the answer; `fallback` is the sentence that stands if the answer never
-- arrives or does not pass.
--
-- Every figure in here comes from migration 091's functions. Nothing is
-- recomputed, so a card and a narrative disagreeing would mean 091 disagreeing
-- with itself.
-- -----------------------------------------------------------------------------
create or replace function dashboard_money_text(p_cents bigint, p_currency text)
returns text
language sql immutable as $$
  select to_char(round(p_cents / 100.0), 'FM999G999G999G999') || ' ' || p_currency
$$;

create or replace function dashboard_facts(
  p_studio_id uuid, p_kind text, p_for_date date default null,
  p_subject_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_name text; v_currency char(3); v_tz text; v_day date;
  v_fig jsonb := '{}'::jsonb; v_allowed text[] := '{}'; v_fallback text;
  v_ctx jsonb := '{}'::jsonb;
  r jsonb; hm jsonb; k jsonb; ins jsonb;
  v_days int := 30;
  v_top jsonb; v_dow text[] := array['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  m record; v_draft jsonb; v_spend bigint; v_rank int; v_gap int;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'dashboard facts are for owners, managers and the backend'
      using errcode = 'PT403';
  end if;
  select s.name, s.currency, s.timezone into v_name, v_currency, v_tz
    from studios s where s.id = p_studio_id;
  if v_name is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_day := coalesce(p_for_date, studio_today(p_studio_id));

  if p_kind = 'revenue' then
    r := dashboard_revenue(p_studio_id, v_day - (v_days - 1), v_day);
    if (r ->> 'state') = 'empty' then
      return jsonb_build_object('skip', true,
        'reason', 'no payments have ever been recorded, so there is nothing to explain');
    end if;

    v_fig := jsonb_build_object(
      'total',       jsonb_build_object('what','money taken in the period',
                       'text', dashboard_money_text((r->>'total_cents')::bigint, v_currency),
                       'n', round((r->>'total_cents')::bigint / 100.0)),
      'prior',       jsonb_build_object('what','money taken in the period before',
                       'text', dashboard_money_text((r->'trend'->>'prior')::bigint, v_currency),
                       'n', round((r->'trend'->>'prior')::bigint / 100.0)),
      'change_pct',  jsonb_build_object('what','per cent change against that period',
                       'text', coalesce((r->'trend'->>'pct'), 'not comparable'),
                       'n', (r->'trend'->>'pct')::numeric),
      'direction',   jsonb_build_object('what','which way it moved',
                       'text', r->'trend'->>'direction'),
      'days',        jsonb_build_object('what','length of the period in days','text', v_days::text, 'n', v_days),
      'bookings',    jsonb_build_object('what','bookings made in the period',
                       'text', r->'counts'->>'bookings', 'n', (r->'counts'->>'bookings')::numeric),
      'memberships_sold', jsonb_build_object('what','memberships sold in the period',
                       'text', r->'counts'->>'memberships_sold', 'n', (r->'counts'->>'memberships_sold')::numeric),
      'by_source',   r -> 'by_source');

    -- Every token the answer may contain: the figures above, plus each
    -- source's own amount and share.
    select array_agg(distinct t) into v_allowed from (
      select round((r->>'total_cents')::bigint / 100.0)::text as t
      union all select round((r->'trend'->>'prior')::bigint / 100.0)::text
      union all select abs((r->'trend'->>'pct')::numeric)::text where (r->'trend'->>'pct') is not null
      union all select v_days::text
      union all select (r->'counts'->>'bookings')
      union all select (r->'counts'->>'memberships_sold')
      union all select round((s->>'cents')::bigint / 100.0)::text from jsonb_array_elements(r->'by_source') s
      union all select (s->>'pct') from jsonb_array_elements(r->'by_source') s
    ) x where t is not null;

    select s into v_top from jsonb_array_elements(r->'by_source') s limit 1;
    v_fallback := 'You took ' || dashboard_money_text((r->>'total_cents')::bigint, v_currency)
      || ' in the last ' || v_days || ' days'
      || case when (r->'trend'->>'pct') is null then '.'
              else ', ' || abs((r->'trend'->>'pct')::numeric) || '% '
                   || case when (r->'trend'->>'direction') = 'down' then 'less' else 'more' end
                   || ' than the ' || v_days || ' days before.' end
      || case when v_top is null then ''
              else ' ' || (v_top->>'label') || ' were ' || (v_top->>'pct') || '% of it.' end;
    v_ctx := jsonb_build_object('period_days', v_days, 'currency', v_currency);

  elsif p_kind = 'attendance' then
    hm := dashboard_heatmap(p_studio_id, 90);
    -- jsonb_typeof, not IS NULL. jsonb_build_object with a SQL NULL stores a
    -- JSON null, and `hm -> 'peak'` reads that back as the jsonb value 'null'
    -- — which is not SQL NULL, so `is null` is false and the guard never
    -- fires. Found by a studio with classes but too few in any one slot to
    -- call a pattern.
    if (hm ->> 'state') = 'empty'
       or hm -> 'peak' is null or jsonb_typeof(hm -> 'peak') = 'null' then
      return jsonb_build_object('skip', true,
        'reason', 'not enough classes have run to see a pattern');
    end if;
    v_fig := jsonb_build_object(
      'peak_day',   jsonb_build_object('what','busiest day','text', v_dow[(hm->'peak'->>'dow')::int + 1]),
      'peak_hour',  jsonb_build_object('what','busiest hour, 24-hour clock','text', lpad(hm->'peak'->>'hour', 2, '0') || ':00',
                                       'n', (hm->'peak'->>'hour')::numeric),
      'peak_pct',   jsonb_build_object('what','how full that slot runs','text', hm->'peak'->>'occupancy',
                                       'n', (hm->'peak'->>'occupancy')::numeric),
      'peak_classes', jsonb_build_object('what','classes counted in that slot','text', hm->'peak'->>'classes',
                                       'n', (hm->'peak'->>'classes')::numeric),
      'quiet_day',  jsonb_build_object('what','quietest day','text', v_dow[(hm->'quiet'->>'dow')::int + 1]),
      'quiet_hour', jsonb_build_object('what','quietest hour','text', lpad(hm->'quiet'->>'hour', 2, '0') || ':00',
                                       'n', (hm->'quiet'->>'hour')::numeric),
      'quiet_pct',  jsonb_build_object('what','how full that slot runs','text', hm->'quiet'->>'occupancy',
                                       'n', (hm->'quiet'->>'occupancy')::numeric),
      'window_days', jsonb_build_object('what','how far back this looks','text','90','n',90));

    v_allowed := array[
      (hm->'peak'->>'hour'), (hm->'peak'->>'occupancy'), (hm->'peak'->>'classes'),
      (hm->'quiet'->>'hour'), (hm->'quiet'->>'occupancy'), (hm->'quiet'->>'classes'), '90',
      lpad(hm->'peak'->>'hour', 2, '0') || '00', lpad(hm->'quiet'->>'hour', 2, '0') || '00'];

    v_fallback := v_dow[(hm->'peak'->>'dow')::int + 1] || ' at '
      || lpad(hm->'peak'->>'hour', 2, '0') || ':00 is your fullest slot, running '
      || (hm->'peak'->>'occupancy') || '% across ' || (hm->'peak'->>'classes')
      || ' classes. ' || v_dow[(hm->'quiet'->>'dow')::int + 1] || ' at '
      || lpad(hm->'quiet'->>'hour', 2, '0') || ':00 is the quietest, at '
      || (hm->'quiet'->>'occupancy') || '%.';
    v_ctx := jsonb_build_object('window_days', 90, 'timezone', v_tz);

  elsif p_kind = 'lead' then
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'type', i.type, 'severity', i.severity, 'title', i.title,
             'observation', i.observation, 'why_it_matters', i.why_it_matters,
             'impact', case when i.estimated_impact_cents is null then null
                            else dashboard_money_text(i.estimated_impact_cents, v_currency) end)
             order by case i.severity when 'urgent' then 0 when 'warning' then 1 else 2 end,
                      i.estimated_impact_cents desc nulls last)
      into ins
      from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = v_day and i.status = 'new';

    if ins is null or jsonb_array_length(ins) = 0 then
      return jsonb_build_object('skip', true,
        -- SAYING NOTHING IS A FEATURE. A brief that manufactures five items
        -- every morning to look busy trains the owner to stop reading it.
        'reason', 'nothing needs the owner today, which is an honest answer and not a gap');
    end if;

    v_fig := jsonb_build_object('insights', ins,
      'count', jsonb_build_object('what','how many are open','text', jsonb_array_length(ins)::text,
                                  'n', jsonb_array_length(ins)));
    select array_agg(distinct t) into v_allowed from (
      select jsonb_array_length(ins)::text as t
      union all select regexp_replace(x, '[^0-9.]', '', 'g')
        from jsonb_array_elements(ins) i,
             lateral unnest(narrative_numbers((i->>'observation') || ' ' || (i->>'title')
                            || ' ' || coalesce(i->>'impact',''))) x
    ) y where t is not null and t <> '';

    v_fallback := (ins->0->>'title') || ' — ' || (ins->0->>'observation');
    v_ctx := jsonb_build_object('open_insights', jsonb_array_length(ins));

  elsif p_kind = 'draft' then
    -- The message a retention insight offers to send. The DETERMINISTIC draft
    -- from migration 022 is the fallback, so the compose screen always has
    -- something in the field; the model's job is to make it sound like a
    -- person wrote it, and to use the two facts that make it land — how long
    -- it has been, and what this member is worth.
    --
    -- "IT NAMES PEOPLE AND MONEY." "Maria hasn't been in for three weeks and
    -- she is your fourth-highest spender this year" lands; "retention risk
    -- detected" does not. Both of those numbers are computed here.
    select mm.id, mm.first_name, coalesce(mm.preferred_name, mm.first_name) as calls_them,
           mm.health_band, mm.health_reason
      into m from members mm
     where mm.id = p_subject_id and mm.studio_id = p_studio_id;
    if m.id is null then
      raise exception 'no such member here' using errcode = 'PT404';
    end if;

    v_draft := message_draft_for(p_subject_id);
    select coalesce(sum(p.amount_cents), 0)::bigint into v_spend
      from payments p where p.member_id = p_subject_id
       and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= now() - interval '365 days';
    select count(*) + 1 into v_rank from (
      select mm.id, coalesce(sum(p.amount_cents), 0) tot
        from members mm left join payments p on p.member_id = mm.id
             and p.status in ('succeeded','partially_refunded')
             and coalesce(p.paid_at, p.created_at) >= now() - interval '365 days'
       where mm.studio_id = p_studio_id and mm.status <> 'archived'
       group by mm.id) t where t.tot > v_spend;
    select (studio_today(p_studio_id) - max((ci.checked_in_at at time zone v_tz)::date))
      into v_gap from check_ins ci where ci.member_id = p_subject_id;

    v_fig := jsonb_build_object(
      'name',       jsonb_build_object('what','what to call them','text', m.calls_them),
      'band',       jsonb_build_object('what','their health band','text', m.health_band),
      'reason',     jsonb_build_object('what','why, in the words the studio already uses','text', m.health_reason),
      'days_since', jsonb_build_object('what','days since their last visit',
                      'text', coalesce(v_gap::text, 'never been in'), 'n', v_gap),
      'spend_year', jsonb_build_object('what','what they have spent in the last year',
                      'text', dashboard_money_text(v_spend, v_currency),
                      'n', round(v_spend / 100.0)),
      'spend_rank', jsonb_build_object('what','where that ranks them among members',
                      'text', v_rank::text, 'n', v_rank),
      'subject',    jsonb_build_object('what','the deterministic subject line','text', v_draft ->> 'subject'));

    select array_agg(distinct t) into v_allowed from (
      select coalesce(v_gap::text, '') as t
      union all select round(v_spend / 100.0)::text
      union all select v_rank::text
      union all select x from unnest(narrative_numbers(coalesce(m.health_reason,'') || ' '
                                     || coalesce(v_draft ->> 'body',''))) x
    ) y where t is not null and t <> '';

    v_fallback := v_draft ->> 'body';
    v_ctx := jsonb_build_object(
      'subject', v_draft ->> 'subject',
      'template_key', v_draft ->> 'template_key',
      'marketing_opt_in', v_draft -> 'marketing_opt_in',
      'never_sends_itself', 'This is a draft. It lands in an editable field and a person presses send.');
  else
    raise exception 'unknown narrative kind %', p_kind using errcode = 'PT422';
  end if;

  return jsonb_build_object(
    'studio', v_name, 'currency', v_currency, 'date', v_day, 'kind', p_kind,
    'subject_id', p_subject_id,
    'figures', v_fig, 'allowed', to_jsonb(coalesce(v_allowed, '{}')),
    'fallback', v_fallback, 'context', v_ctx);
end $$;

-- -----------------------------------------------------------------------------
-- THE PROMPT
--
-- Its whole job is the boundary. The figures arrive already computed and the
-- model is told, in the first line it reads, that it may not produce one —
-- and narrative_offending_number() enforces that afterwards regardless of
-- whether the instruction was followed. Belt and braces, because a prompt is a
-- request and a verifier is a rule.
-- -----------------------------------------------------------------------------
create or replace function narrative_prompt(p_kind text) returns text
language sql immutable as $$
  select case p_kind
  when 'draft' then
    'You are drafting a short message from a boutique fitness studio to one of '
    || 'its members, for a member of staff to read, edit and send. You are not '
    || 'sending it.' || E'\n\n'
    || 'You are given figures that have ALREADY BEEN COMPUTED. You must not '
    || 'compute, estimate, round or infer any number. Every numeral you write '
    || 'must appear in the "allowed" array exactly as it is given there. If a '
    || 'figure you want is not in that array, write the message without it.'
    || E'\n\n'
    || 'Warm, brief, and like one person writing to another. Use the name given. '
    || 'Do not mention health bands, scores, risk, systems or data. Do not '
    || 'guilt them about not coming. No emoji, no markdown, no subject line.'
    || E'\n\n' || 'Reply with JSON only: {"text": "the message body"}'
  when 'lead' then
    'You are choosing which one thing a studio owner should look at first this '
    || 'morning, from a list that has already been produced for them.' || E'\n\n'
    || 'You are given figures that have ALREADY BEEN COMPUTED. You must not '
    || 'compute, estimate, round or infer any number. Every numeral you write '
    || 'must appear in the "allowed" array exactly as it is given there.'
    || E'\n\n'
    || 'Choose exactly one of the insights by its id. You may only choose from '
    || 'the list; you may not add, merge or invent one. Write one or two '
    || 'sentences saying what it is and why it is the one that matters today. '
    || 'Name people and amounts where the figures give them. Do not tell the '
    || 'owner what to do — the screen carries the button.' || E'\n\n'
    || 'Plain sentences. No greeting, no heading, no bullet points, no markdown, '
    || 'no emoji.' || E'\n\n'
    || 'Reply with JSON only: {"text": "...", "lead_id": "<one id from the list>"}'
  else
    'You write two or three sentences for the dashboard of a boutique fitness '
    || 'studio, for the owner to read in the morning.' || E'\n\n'
    || 'You are given figures that have ALREADY BEEN COMPUTED. You must not '
    || 'compute, estimate, round or infer any number. Every numeral you write '
    || 'must appear in the "allowed" array exactly as it is given there. If a '
    || 'figure you want is not in that array, write the sentence without it. Do '
    || 'not add up, compare or convert anything.' || E'\n\n'
    || 'Say what moved and what carried it. Plain sentences, as one person to '
    || 'another. No greeting, no heading, no bullet points, no markdown, no '
    || 'emoji, no exclamation marks. Do not tell the owner what to do — the '
    || 'screen carries the buttons.' || E'\n\n'
    || 'Reply with JSON only: {"text": "..."}'
  end
$$;

-- -----------------------------------------------------------------------------
-- Queue one narrative
--
-- THE FALLBACK IS WRITTEN FIRST. The row is complete and useful before a
-- single byte leaves the database, so every failure after this point — no key,
-- a timeout, a refusal, an outage at Anthropic — degrades to a correct
-- sentence rather than to a gap.
-- -----------------------------------------------------------------------------
create or replace function queue_dashboard_narrative(
  p_studio_id uuid, p_kind text, p_subject_id uuid default null,
  p_for_date date default null)
returns uuid
language plpgsql security definer set search_path = public, net as $$
declare
  v_day date; v_facts jsonb; v_id uuid; v_key text; v_req bigint;
  v_model text; v_body jsonb;
begin
  if not is_service_context() then
    raise exception 'narratives are generated by the backend, not by a user'
      using errcode = 'PT403';
  end if;
  v_day := coalesce(p_for_date, studio_today(p_studio_id));
  v_facts := dashboard_facts(p_studio_id, p_kind, v_day, p_subject_id);

  -- Nothing to say is a valid answer and is recorded as one. A brief that
  -- manufactures an item every morning to look busy trains the owner to
  -- ignore it.
  if coalesce((v_facts ->> 'skip')::boolean, false) then
    insert into dashboard_narratives
      (studio_id, for_date, kind, subject_id, status, fallback, facts)
    values (p_studio_id, v_day, p_kind, p_subject_id, 'skipped',
            v_facts ->> 'reason', v_facts)
    on conflict (studio_id, for_date, kind,
                 coalesce(subject_id, '00000000-0000-0000-0000-000000000000'::uuid))
    do update set status = 'skipped', fallback = excluded.fallback, facts = excluded.facts
    returning id into v_id;
    return v_id;
  end if;

  insert into dashboard_narratives
    (studio_id, for_date, kind, subject_id, status, fallback, facts,
     model, prompt_version)
  values (p_studio_id, v_day, p_kind, p_subject_id, 'pending',
          v_facts ->> 'fallback', v_facts,
          dashboard_ai_setting('model'), dashboard_ai_setting('prompt_version'))
  on conflict (studio_id, for_date, kind,
               coalesce(subject_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set status = 'pending', fallback = excluded.fallback,
                facts = excluded.facts, model = excluded.model,
                prompt_version = excluded.prompt_version,
                body = null, error = null, net_request_id = null,
                queued_at = now(), completed_at = null
  returning id into v_id;

  if dashboard_ai_setting('enabled') <> '1' then
    update dashboard_narratives set status = 'failed', completed_at = now(),
           error = 'The AI layer is switched off. The written figures stand.'
     where id = v_id;
    return v_id;
  end if;

  v_key := anthropic_api_key();
  if v_key is null then
    -- An ordinary state, not an error: a fresh local stack has no key. The
    -- row keeps its fallback and the dashboard is complete without it.
    update dashboard_narratives set status = 'failed', completed_at = now(),
           error = 'ANTHROPIC_API_KEY is not configured. Set it in Vault, or as '
                   'app.anthropic_api_key on the database. The written figures stand.'
     where id = v_id;
    return v_id;
  end if;

  v_model := dashboard_ai_setting('model');
  v_body := jsonb_build_object(
    'model', v_model,
    'max_tokens', dashboard_ai_setting('max_tokens')::int,
    'system', narrative_prompt(p_kind),
    'messages', jsonb_build_array(jsonb_build_object(
      'role', 'user',
      'content', jsonb_pretty(v_facts - 'fallback'))));

  v_req := net.http_post(
    url := dashboard_ai_setting('api_url'),
    headers := jsonb_build_object(
      'x-api-key', v_key,
      'anthropic-version', dashboard_ai_setting('api_version'),
      'content-type', 'application/json'),
    body := v_body,
    timeout_milliseconds := dashboard_ai_setting('timeout_ms')::int);

  -- The key is deliberately NOT stored. request_body is kept so a wrong
  -- sentence can be traced to what was sent; the header it went with is not
  -- part of that and would put a live credential in a table managers can read.
  update dashboard_narratives
     set net_request_id = v_req, request_body = v_body where id = v_id;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- Read the answers back and CHECK THEM
--
-- Two passes because pg_net is asynchronous — the same shape as
-- reconcile_notification_sends(), and for the same reason: marking a row ready
-- at post time would be recording a hope.
-- -----------------------------------------------------------------------------
create or replace function reconcile_dashboard_narratives()
returns jsonb
language plpgsql security definer set search_path = public, net as $$
declare
  r record; resp record; v_txt text; v_json jsonb; v_lead uuid;
  v_allowed text[]; v_bad text;
  n_ready int := 0; n_rejected int := 0; n_failed int := 0; n_waiting int := 0;
begin
  if not is_service_context() then
    raise exception 'narratives are reconciled by the backend, not by a user'
      using errcode = 'PT403';
  end if;

  for r in select * from dashboard_narratives
            where status = 'pending' and net_request_id is not null
  loop
    select * into resp from net._http_response where id = r.net_request_id;
    if not found then
      if r.queued_at < now() - interval '10 minutes' then
        update dashboard_narratives
           set status = 'failed', completed_at = now(),
               error = 'No answer within ten minutes. The written figures stand.'
         where id = r.id;
        n_failed := n_failed + 1;
      else
        n_waiting := n_waiting + 1;
      end if;
      continue;
    end if;

    if resp.status_code is null or resp.status_code not between 200 and 299 then
      update dashboard_narratives
         set status = 'failed', completed_at = now(),
             response_body = case when resp.content is null then null
                                  else jsonb_build_object('raw', left(resp.content, 2000)) end,
             error = coalesce(resp.error_msg, 'HTTP ' || coalesce(resp.status_code::text, '?'))
       where id = r.id;
      n_failed := n_failed + 1;
      continue;
    end if;

    begin
      v_txt := (resp.content::jsonb -> 'content' -> 0 ->> 'text');
      -- A fenced block is still a valid answer wearing markdown.
      v_txt := regexp_replace(coalesce(v_txt, ''), '^\s*```[a-z]*\s*|\s*```\s*$', '', 'g');
      v_json := v_txt::jsonb;
    exception when others then
      update dashboard_narratives
         set status = 'failed', completed_at = now(),
             response_body = jsonb_build_object('raw', left(coalesce(resp.content,''), 2000)),
             error = 'The answer was not the JSON that was asked for.'
       where id = r.id;
      n_failed := n_failed + 1;
      continue;
    end;

    select array_agg(value #>> '{}') into v_allowed
      from jsonb_array_elements(r.facts -> 'allowed');
    v_bad := narrative_offending_number(v_json ->> 'text', coalesce(v_allowed, '{}'));

    -- A number nothing computed. Refused outright — the deterministic
    -- sentence is already correct and on the screen, and a caveat under a
    -- wrong figure is not a fix.
    if v_bad is not null then
      update dashboard_narratives
         set status = 'rejected', completed_at = now(),
             response_body = v_json,
             error = 'Refused: the sentence contained ' || v_bad
                     || ', which is not one of the figures it was given.'
       where id = r.id;
      n_rejected := n_rejected + 1;
      continue;
    end if;

    -- For the lead, the chosen insight must be one that was offered. The
    -- model may reorder the set; it may not add to it.
    v_lead := null;
    if r.kind = 'lead' then
      begin
        v_lead := (v_json ->> 'lead_id')::uuid;
      exception when others then v_lead := null; end;
      if v_lead is null or not exists (
           select 1 from jsonb_array_elements(r.facts -> 'figures' -> 'insights') i
            where (i ->> 'id')::uuid = v_lead) then
        update dashboard_narratives
           set status = 'rejected', completed_at = now(), response_body = v_json,
               error = 'Refused: it led on something that was not in the list.'
         where id = r.id;
        n_rejected := n_rejected + 1;
        continue;
      end if;
    end if;

    if coalesce(trim(v_json ->> 'text'), '') = '' then
      update dashboard_narratives
         set status = 'failed', completed_at = now(), response_body = v_json,
             error = 'Empty answer.'
       where id = r.id;
      n_failed := n_failed + 1;
      continue;
    end if;

    update dashboard_narratives
       set status = 'ready', completed_at = now(), body = trim(v_json ->> 'text'),
           lead_insight_id = v_lead, response_body = v_json, error = null
     where id = r.id;
    n_ready := n_ready + 1;
  end loop;

  return jsonb_build_object('ready', n_ready, 'rejected', n_rejected,
                            'failed', n_failed, 'waiting', n_waiting);
end $$;

-- -----------------------------------------------------------------------------
-- message_draft_for() learns the backend
--
-- Re-issued from migration 033's FILE, not from the live database — a copy
-- taken with pg_get_functiondef from a database this session has been
-- iterating against has twice contained an earlier draft of the very
-- migration being written.
--
-- create or replace, never drop-then-create: a drop discards the ACL and the
-- function is reborn with the hosted default grant for anon and authenticated.
-- -----------------------------------------------------------------------------
create or replace function message_draft_for(p_member_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m        members%rowtype;
  v_studio studios%rowtype;
  v_key    text;
  t        message_templates%rowtype;
  v_days   int;
  v_slot   text;
  v_slot_line text;
  v_subject text;
  v_body    text;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  -- Desk-up, OR the backend. Migration 092 drafts these ahead of time on a
  -- cron so the message is already written when somebody presses Message, and
  -- pg_cron has no JWT — is_desk_up() is correctly false for it. This is a
  -- pure composer with no side effects, and the backend roles bypass RLS
  -- anyway, so the widening reaches nothing that was not already reachable.
  if not (is_desk_up(m.studio_id) or is_service_context()) then
    raise exception 'only owners, managers and front desk may message a member'
      using errcode = 'PT403',
            hint = 'Permissions §12.';
  end if;

  select * into v_studio from studios where id = m.studio_id;

  -- The first signal is the reason the band fired, and the reason decides the
  -- draft. Falling back to the band covers `new`, which has no signals by
  -- design, and `general` covers a member nothing has been computed for.
  v_key := coalesce(
    m.health_signals ->> 0,
    case when m.health_band = 'new' then 'new_member' else null end,
    'general');

  -- A studio's own wording wins over ours.
  select * into t from message_templates
   where key = v_key and (studio_id = m.studio_id or studio_id is null)
   order by studio_id nulls last limit 1;
  if not found then
    select * into t from message_templates where key = 'general' and studio_id is null;
  end if;

  v_days := case when m.last_visit_at is null then null
                 else (current_date - (m.last_visit_at at time zone v_studio.timezone)::date) end;

  -- Their usual slot: the day and hour they turn up at most often, in studio
  -- time. Six visits is the same floor Decision 14 uses before it will call
  -- anything a rhythm.
  -- Grouped on the class's start time, not the check-in's. People arrive at
  -- 06:37 and 06:54 for the same 07:00 class, so grouping on when they walked
  -- through the door means no two visits ever match and every member looks
  -- like they have no usual slot.
  select to_char(o.starts_at at time zone v_studio.timezone, 'FMDay HH24:MI')
    into v_slot
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
   where ci.member_id = p_member_id
   group by to_char(o.starts_at at time zone v_studio.timezone, 'FMDay HH24:MI')
  having count(*) >= 3
   order by count(*) desc, max(o.starts_at) desc
   limit 1;

  v_slot_line := case
    when v_slot is null
      then 'There is space in most classes this week if you fancy it.'
    else format('Your usual %s still has space if you fancy it.', v_slot)
  end;

  v_subject := replace(replace(t.subject, '{studio}', v_studio.name),
                       '{first_name}', m.first_name);
  v_body := t.body;
  v_body := replace(v_body, '{first_name}',  m.first_name);
  v_body := replace(v_body, '{studio}',      v_studio.name);
  v_body := replace(v_body, '{gap_phrase}',  message_gap_phrase(v_days));
  v_body := replace(v_body, '{slot_line}',   v_slot_line);
  v_body := replace(v_body, '{joined_phrase}',
                    message_gap_phrase(current_date - m.joined_on) || ' ago');

  return jsonb_build_object(
    'template_key', t.key,
    'subject',      v_subject,
    'body',         v_body,
    'marketing_opt_in', m.marketing_opt_in,
    -- A card that failed is something they need to know regardless of what
    -- they ticked; a we-miss-you note is not. The screen decides what to say
    -- about that, but it should not have to work out which is which.
    'transactional', t.key in ('payment_state', 'expiry_declining_use'));
end $$;

-- -----------------------------------------------------------------------------
-- What the screen reads
--
-- Always returns a sentence. `source` is 'ai' when a verified answer came
-- back and 'written' when the deterministic one stands — which is also what
-- happens on a fresh stack with no key, so this is the normal case as often as
-- it is the failure case.
--
-- DELIBERATELY NOT LABELLED IN THE UI. The Bible's fourth principle is that AI
-- should be invisible, and a badge on every second sentence is the opposite of
-- that. It is also not needed for trust: both sentences are checked against
-- the same figures, so they differ in voice and not in accuracy. `source` is
-- returned so a support conversation can be precise, not so the screen can put
-- a sparkle on it.
-- -----------------------------------------------------------------------------
/**
 * How many days of history the sentence is about, or null where the question
 * has no window (the lead, a member's draft).
 */
create or replace function narrative_covers_days(p_facts jsonb) returns int
language sql immutable as $$
  select coalesce((p_facts -> 'context' ->> 'period_days')::int,
                  (p_facts -> 'context' ->> 'window_days')::int)
$$;

create or replace function dashboard_narrative(
  p_studio_id uuid, p_kind text, p_subject_id uuid default null,
  p_for_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; v_day date;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'the dashboard is for owners and managers' using errcode = 'PT403';
  end if;
  v_day := coalesce(p_for_date, studio_today(p_studio_id));

  select * into r from dashboard_narratives d
   where d.studio_id = p_studio_id and d.for_date = v_day and d.kind = p_kind
     and d.subject_id is not distinct from p_subject_id;

  -- NO ROW YET IS STILL A SENTENCE. The cron may not have run — a fresh
  -- studio, a stack with no key, the first morning after this shipped — and a
  -- block that renders nothing in that case would make the deterministic half
  -- an error path rather than the default. Composing it here costs the same
  -- query the cron would have made and means the screen is never blank.
  if not found then
    declare v_facts jsonb;
    begin
      v_facts := dashboard_facts(p_studio_id, p_kind, v_day, p_subject_id);
      if coalesce((v_facts ->> 'skip')::boolean, false) then
        return jsonb_build_object('state', 'nothing_to_say', 'text', null,
                                  'reason', v_facts ->> 'reason', 'source', 'written');
      end if;
      return jsonb_build_object('state', 'ok', 'text', v_facts ->> 'fallback',
                                'covers_days', narrative_covers_days(v_facts),
                                'source', 'written');
    exception when others then
      return jsonb_build_object('state', 'none', 'text', null, 'source', null);
    end;
  end if;
  if r.status = 'skipped' then
    return jsonb_build_object('state', 'nothing_to_say', 'text', null,
                              'reason', r.fallback, 'source', 'written');
  end if;
  -- THE WINDOW THE SENTENCE DESCRIBES TRAVELS WITH IT. A revenue narrative is
  -- written about 30 days; put it above a 90-day chart and it reads as a
  -- caption for a figure it has never seen — which is the precise failure this
  -- whole layer is arranged to prevent, arriving at the screen instead of at
  -- the model. The caller compares and withholds.
  if r.status = 'ready' then
    return jsonb_build_object('state', 'ok', 'text', r.body, 'source', 'ai',
                              'covers_days', narrative_covers_days(r.facts),
                              'lead_insight_id', r.lead_insight_id);
  end if;
  return jsonb_build_object('state', 'ok', 'text', r.fallback, 'source', 'written',
                            'covers_days', narrative_covers_days(r.facts));
end $$;

-- -----------------------------------------------------------------------------
-- The clock
--
-- Runs AFTER the morning brief, because the lead narrative chooses among the
-- insights the brief produced. A studio qualifies when it has a brief for its
-- own today and no narratives for that date yet, which makes the job
-- idempotent on the state itself rather than on a job_runs claim — the same
-- rule migration 075's sweep follows, and the reason a fifteen-minute cadence
-- is safe.
-- -----------------------------------------------------------------------------
create or replace function run_due_dashboard_narratives()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record; m record; n_studios int := 0; n_queued int := 0; v_drafts int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  for s in
    select b.studio_id, b.brief_date
      from morning_briefs b
     where b.brief_date = studio_today(b.studio_id)
       and not exists (select 1 from dashboard_narratives d
                        where d.studio_id = b.studio_id and d.for_date = b.brief_date)
  loop
    n_studios := n_studios + 1;
    perform queue_dashboard_narrative(s.studio_id, 'revenue',    null, s.brief_date);
    perform queue_dashboard_narrative(s.studio_id, 'attendance', null, s.brief_date);
    perform queue_dashboard_narrative(s.studio_id, 'lead',       null, s.brief_date);
    n_queued := n_queued + 3;

    -- A draft per member the brief is already offering to message. Capped,
    -- and only where there is a button that would use it: a draft nobody can
    -- reach is a call to an API for nothing.
    v_drafts := 0;
    for m in
      select distinct i.subject_id
        from ai_insights i
       where i.studio_id = s.studio_id and i.for_date = s.brief_date
         and i.status = 'new' and i.subject_type = 'member'
         and i.subject_id is not null
         and i.action_type in ('message_member','message')
       limit 5
    loop
      perform queue_dashboard_narrative(s.studio_id, 'draft', m.subject_id, s.brief_date);
      n_queued := n_queued + 1; v_drafts := v_drafts + 1;
    end loop;
  end loop;

  return jsonb_build_object('studios', n_studios, 'queued', n_queued);
end $$;

-- -----------------------------------------------------------------------------
-- Closed by default. Functions are executable the moment they are created on
-- this platform — for anon AND authenticated — so every one of these says who
-- may run it. The two that reach the network and the one that returns the key
-- are backend-only; the readers are guarded manager-up INSIDE and granted to
-- authenticated, because the grant is not the guard.
-- -----------------------------------------------------------------------------
revoke execute on function dashboard_ai_setting(text) from public, anon, authenticated;
revoke execute on function anthropic_api_key() from public, anon, authenticated;
revoke execute on function narrative_prompt(text) from public, anon, authenticated;
revoke execute on function narrative_numbers(text) from public, anon, authenticated;
revoke execute on function narrative_offending_number(text, text[]) from public, anon, authenticated;
revoke execute on function queue_dashboard_narrative(uuid, text, uuid, date) from public, anon, authenticated;
revoke execute on function reconcile_dashboard_narratives() from public, anon, authenticated;
revoke execute on function run_due_dashboard_narratives() from public, anon, authenticated;
revoke execute on function dashboard_facts(uuid, text, date, uuid) from public, anon, authenticated;
-- Called only from inside dashboard_narrative(), which is SECURITY DEFINER
-- and runs as the owner. No client role needs it, and "closed to everything
-- outside" is a stronger statement than a check.
revoke execute on function narrative_covers_days(jsonb) from public, anon, authenticated;
grant execute on function narrative_covers_days(jsonb) to service_role;
revoke execute on function dashboard_narrative(uuid, text, uuid, date) from public, anon, authenticated;
revoke execute on function dashboard_money_text(bigint, text) from public, anon, authenticated;

grant execute on function dashboard_ai_setting(text) to service_role;
grant execute on function anthropic_api_key() to service_role;
grant execute on function narrative_prompt(text) to service_role;
grant execute on function narrative_numbers(text) to service_role;
grant execute on function narrative_offending_number(text, text[]) to service_role;
grant execute on function queue_dashboard_narrative(uuid, text, uuid, date) to service_role;
grant execute on function reconcile_dashboard_narratives() to service_role;
grant execute on function run_due_dashboard_narratives() to service_role;
grant execute on function dashboard_money_text(bigint, text) to service_role;
-- Guarded manager-up in the body, so the client roles may hold them.
grant execute on function dashboard_facts(uuid, text, date, uuid) to authenticated, service_role;
grant execute on function dashboard_narrative(uuid, text, uuid, date) to authenticated, service_role;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here; narratives will queue when something calls the runner.';
    return;
  end if;
  perform cron.unschedule('studiior-dashboard-narratives');
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('studiior-dashboard-narratives', '*/15 * * * *',
      $c$select run_due_dashboard_narratives()$c$);
    perform cron.schedule('studiior-dashboard-narratives-reconcile', '*/2 * * * *',
      $c$select reconcile_dashboard_narratives()$c$);
  end if;
end $$;
