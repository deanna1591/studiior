-- Decision 78c — "Send me a test" for an editable template.
-- A manager queues ONE notification of a given template to their own staff
-- email, with a sample payload. render_notification (migration 650000) prefers
-- the saved per-studio override, so the test shows exactly what members will
-- get once saved. Clients cannot INSERT into notifications (SELECT-only RLS),
-- so this is the SECURITY DEFINER door, the send_campaign_test shape.
--
-- creates: send_template_test(uuid, text)

create or replace function send_template_test(p_studio_id uuid, p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
  v_studio text;
  v_payload jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'only owners and managers can send a test' using errcode = 'PT403';
  end if;

  select ss.email into v_email
  from studio_staff ss
  where ss.studio_id = p_studio_id and ss.user_id = auth.uid()
    and ss.status = 'active';
  if coalesce(v_email, '') = '' then
    raise exception 'no email on file for your account' using errcode = 'PT422';
  end if;

  select name into v_studio from studios where id = p_studio_id;

  -- A sample so every placeholder renders to something readable.
  v_payload := jsonb_build_object(
    'to_email', v_email,
    'first_name', 'Alex',
    'studio_name', coalesce(v_studio, 'your studio'),
    'plan_name', 'Unlimited Monthly',
    'class_name', 'Reformer Flow',
    'instructor_first_name', 'Ada',
    'when', 'Mon 09 Nov at 07:00',
    'offer_plan_name', 'Intro Pack',
    'offer_ends', '20 Nov 2026',
    'expires_on', '20 Nov 2026',
    'credits_left', '3',
    'buy_url', 'https://example.studiior.app/account/plan',
    'plans_url', 'https://example.studiior.app/account/plan',
    'book_url', 'https://example.studiior.app/book',
    'schedule_url', 'https://example.studiior.app/instructor/schedule'
  );

  insert into notifications (studio_id, recipient_type, member_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'member', null, p_key, 'email',
          v_payload, 'tpl_test:' || p_key || ':' || extract(epoch from clock_timestamp())::bigint,
          now(), 'scheduled');

  return jsonb_build_object('ok', true, 'to_email', v_email);
end;
$$;

revoke execute on function send_template_test(uuid, text) from public, anon;
grant execute on function send_template_test(uuid, text) to authenticated, service_role;
