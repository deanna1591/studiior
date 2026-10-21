-- Decision 79b — AI drafts in the retention composer. Opt-in, default OFF.
--
-- A per-studio toggle and a few lines of "how the studio speaks"; a usage log for
-- later billing and a soft monthly cap; the model id and cap as platform config
-- rows. The API key is a PLATFORM secret in the Next runtime's env — it is never
-- stored here, never in a migration, never per tenant.
--
-- creates: ai_draft_usage (table), ai_draft_count(uuid), ai_draft_gate(uuid),
--          record_ai_draft(uuid, uuid, text, text, int, int), member_sees_ai_drafts()
-- Authorised by Deanna, 21 Oct 2026.

alter table studio_settings add column if not exists ai_drafts_enabled boolean not null default false;
alter table studio_settings add column if not exists studio_voice text;

-- Platform config (notification_config is the existing key/value config, read by
-- the service-role-only notification_setting()). The model can move without a
-- migration; the cap is a soft limit the action enforces.
insert into notification_config (key, value, note) values
  ('ai_drafts_model', 'claude-sonnet-5-5', 'The model that writes retention drafts.'),
  ('ai_drafts_monthly_cap', '200', 'Soft cap on AI drafts per studio per month.')
on conflict (key) do nothing;

-- The usage log — one row per draft, for later billing. No member PII beyond the
-- member id (the name/history that LEFT the database for the draft is not stored).
create table ai_draft_usage (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid references members on delete set null,
  situation     text,
  model         text,
  input_tokens  int,
  output_tokens int,
  staff_id      uuid references profiles,
  created_at    timestamptz not null default now()
);
create index ai_draft_usage_studio_month on ai_draft_usage (studio_id, created_at);

alter table ai_draft_usage enable row level security;
-- Manager-up reads its own studio's usage; writes are the SECURITY DEFINER RPC
-- only (no client insert policy).
create policy ai_draft_usage_read on ai_draft_usage for select using (
  coalesce(is_manager_up(studio_id), false));
grant select on ai_draft_usage to authenticated;
grant all on ai_draft_usage to service_role;

-- ai_draft_count — this studio's drafts in the current studio-local month.
create or replace function ai_draft_count(p_studio_id uuid)
returns int language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_month_start date; v_n int;
begin
  if not retention_can_act(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_month_start := date_trunc('month', (now() at time zone v_tz))::date;
  select count(*)::int into v_n from ai_draft_usage
   where studio_id = p_studio_id
     and (created_at at time zone v_tz)::date >= v_month_start;
  return coalesce(v_n, 0);
end $$;
revoke execute on function ai_draft_count(uuid) from public, anon;
grant  execute on function ai_draft_count(uuid) to authenticated, service_role;

-- ai_draft_gate — everything the server action needs to decide: is the toggle on,
-- the studio voice, the model, the cap, and how many drafts this month. The model
-- id and cap are not secrets; the API KEY is never returned (it lives in env).
create or replace function ai_draft_gate(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_enabled boolean; v_voice text; v_model text; v_cap int; v_used int;
begin
  if not retention_can_act(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  select ai_drafts_enabled, studio_voice into v_enabled, v_voice
    from studio_settings where studio_id = p_studio_id;
  v_model := coalesce(nullif(notification_setting('ai_drafts_model'), ''), 'claude-sonnet-5-5');
  v_cap   := coalesce(nullif(notification_setting('ai_drafts_monthly_cap'), '')::int, 200);
  v_used  := ai_draft_count(p_studio_id);
  return jsonb_build_object('enabled', coalesce(v_enabled, false), 'voice', v_voice,
                            'model', v_model, 'cap', v_cap, 'used', v_used);
end $$;
revoke execute on function ai_draft_gate(uuid) from public, anon;
grant  execute on function ai_draft_gate(uuid) to authenticated, service_role;

-- record_ai_draft — the action logs one row per successful draft (service writes
-- via this definer; no client insert policy on the table).
create or replace function record_ai_draft(
  p_studio_id uuid, p_member_id uuid, p_situation text, p_model text,
  p_input_tokens int, p_output_tokens int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not retention_can_act(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  insert into ai_draft_usage (studio_id, member_id, situation, model, input_tokens, output_tokens, staff_id)
    values (p_studio_id, p_member_id, p_situation, p_model, p_input_tokens, p_output_tokens, auth.uid())
    returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function record_ai_draft(uuid, uuid, text, text, int, int) from public, anon;
grant  execute on function record_ai_draft(uuid, uuid, text, text, int, int) to authenticated, service_role;

-- member_sees_ai_drafts — a member's own studio's toggle, for the one-line
-- privacy sentence on their account page. Resolves the studio from auth.uid().
create or replace function member_sees_ai_drafts()
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_on boolean;
begin
  select coalesce(bool_or(ss.ai_drafts_enabled), false) into v_on
    from members m join studio_settings ss on ss.studio_id = m.studio_id
   where m.user_id = auth.uid();
  return coalesce(v_on, false);
end $$;
revoke execute on function member_sees_ai_drafts() from public, anon;
grant  execute on function member_sees_ai_drafts() to authenticated, service_role;
