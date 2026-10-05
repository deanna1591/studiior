-- Decision 65 — the Reply-To header carries the studio's name.
--
-- creates: resend_reply_to(text, text)
-- re-issues: send_via_resend(text, text, text, text, text, text, text, text)
--
-- The reply-to address has been driven by studios.contact_email (migration 034)
-- since before this decision — render_notification returns it, deliver_notification
-- passes it, and send_via_resend already puts `reply_to` in the Resend body. The
-- ONLY gap vs Decision 65 was the display name: the header carried the bare email.
--
-- resend_reply_to is the one pure definition of the header value, so the test
-- asserts it directly rather than re-implementing the wrap (send_via_resend posts
-- its body via net.http_post and never returns it). No column, no UI — contact_email
-- and its validated Branding field already exist.

-- The reply-to header value: null (no header) for an empty address; left as-is for
-- an address that already carries a display part; otherwise "{name} <email>" with
-- the same quote wash send_via_resend uses for the From name.
create function resend_reply_to(p_from_name text, p_address text) returns text
language sql immutable as $$
  select case
    when nullif(p_address, '') is null then null
    when p_address like '%<%>%' then p_address
    else replace(p_from_name, '"', '') || ' <' || p_address || '>'
  end;
$$;
revoke execute on function resend_reply_to(text, text) from public, anon, authenticated;
grant  execute on function resend_reply_to(text, text) to service_role;

-- send_via_resend re-issued byte-for-byte from 20260832170000 with the one change:
-- the reply_to goes through resend_reply_to. Signature and ACL unchanged (create or
-- replace keeps the ACL; re-asserted for the record).
create or replace function send_via_resend(
  p_to text, p_from_name text, p_reply_to text,
  p_subject text, p_text text, p_html text,
  p_ics text default null, p_from_domain text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; v_body jsonb; v_method text; v_reply text;
begin
  v_key := notification_api_key();
  if v_key is null then
    raise exception 'RESEND_API_KEY is not configured'
      using errcode = 'PT503',
            hint = 'Set it in Vault as RESEND_API_KEY, or as app.resend_api_key '
                   'on the database. It is deliberately not in the repo.';
  end if;

  -- Campaign mail may ride its own verified domain; everything else, and a null
  -- domain, uses the transactional from_domain exactly as before.
  v_from := replace(p_from_name, '"', '') || ' <notifications@'
            || coalesce(nullif(p_from_domain, ''), notification_setting('from_domain')) || '>';

  v_body := jsonb_build_object('from', v_from, 'to', jsonb_build_array(p_to),
                               'subject', p_subject, 'text', p_text, 'html', p_html);
  -- Decision 65: replies go to the studio, named. Null/empty address → no header.
  v_reply := resend_reply_to(p_from_name, p_reply_to);
  if v_reply is not null then
    v_body := v_body || jsonb_build_object('reply_to', v_reply);
  end if;

  if nullif(p_ics, '') is not null then
    v_method := coalesce(substring(p_ics from 'METHOD:([A-Z]+)'), 'PUBLISH');
    v_body := v_body || jsonb_build_object('attachments', jsonb_build_array(
      jsonb_build_object(
        'filename', 'studiior.ics',
        'content', translate(encode(convert_to(p_ics, 'UTF8'), 'base64'), E'\n', ''),
        'content_type', 'text/calendar; charset=utf-8; method=' || v_method)));
  end if;

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := v_body,
    timeout_milliseconds := 8000);
end $$;
revoke execute on function send_via_resend(text,text,text,text,text,text,text,text)
  from public, anon, authenticated;
grant  execute on function send_via_resend(text,text,text,text,text,text,text,text)
  to service_role;
