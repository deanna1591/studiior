-- =============================================================================
-- Migration 032: pg_net belongs in the migrations, not in somebody's memory
-- =============================================================================
-- pg_net was enabled by hand on the hosted project, so from migration 030
-- onwards the repo stopped describing the database. Every local `db reset`
-- passed, because the local stack ships pg_net pre-installed too. A fresh
-- hosted project built from this repo would apply all thirty-one migrations
-- cleanly and then fail on the first cron tick with:
--
--     schema "net" does not exist
--
-- which is a failure a minute after deploy, in a background job, on a studio
-- nobody is watching yet. It is the same class of mistake as migration 013:
-- what is *actually there* on hosted is not what this repo creates.
--
-- WHERE PG_NET ACTUALLY LIVES — checked on hosted before changing anything,
-- because the obvious guess is wrong in an expensive direction:
--
--   pg_extension.extnamespace  = extensions   (hosted AND local)
--   all 15 of its objects      = net          (hosted AND local)
--
-- pg_net's install script creates schema `net` itself and puts every function
-- and table there, whatever schema the extension is registered against. So
-- `net.http_post` is correct on both, `extensions.http_post` exists on neither,
-- and "re-qualify the calls to extensions." would have broken production
-- sending outright. The calls in migration 030 were already schema-qualified
-- and are left exactly as they are.
--
-- What is wrong is the search_path on two of them: `public, net`. The `net`
-- entry does nothing — both references are qualified — but it widens the path
-- of a SECURITY DEFINER function for no benefit, which is precisely what
-- migration 011 pinned these against. Narrowed to `public` here.
--
-- Replaced with `create or replace` and the identity arguments unchanged, so
-- the grants at the end of migration 030 survive. Both bodies were fingerprinted
-- against hosted first (md5 of prosrc, live vs local: identical), so this is a
-- fix forward from the live definition and not from the file's hopes.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_net is not available here; notifications will queue and '
                 'never send. send_due_notifications() will raise on the first '
                 'call rather than silently doing nothing.';
    return;
  end if;

  -- Registered against `extensions` to match hosted exactly. This only sets
  -- extnamespace; the objects land in `net` either way.
  if exists (select 1 from pg_namespace where nspname = 'extensions') then
    create extension if not exists pg_net with schema extensions;
  else
    create extension if not exists pg_net;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- The same two functions, with the search_path narrowed back to public
-- -----------------------------------------------------------------------------

create or replace function send_via_resend(
  p_to text, p_from_name text, p_subject text, p_text text, p_html text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text;
begin
  v_key := notification_api_key();
  if v_key is null then
    raise exception 'RESEND_API_KEY is not configured'
      using errcode = 'PT503',
            hint = 'Set it in Vault as RESEND_API_KEY, or as app.resend_api_key '
                   'on the database. It is deliberately not in the repo.';
  end if;

  v_from := replace(p_from_name, '"', '') || ' <notifications@'
            || notification_setting('from_domain') || '>';

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := jsonb_build_object('from', v_from, 'to', jsonb_build_array(p_to),
                               'subject', p_subject, 'text', p_text, 'html', p_html),
    timeout_milliseconds := 8000);
end $$;

create or replace function reconcile_notification_sends() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n_sent int := 0; n_failed int := 0; resp record;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in select * from notifications
            where status = 'sending' and net_request_id is not null
  loop
    select * into resp from net._http_response where id = r.net_request_id;
    if not found then
      -- Still in flight, unless it has been too long to be believable.
      if r.claimed_at < now() - interval '10 minutes' then
        update notifications
           set status = 'failed', failed_at = now(),
               error = 'No response from the provider within ten minutes.'
         where id = r.id;
        n_failed := n_failed + 1;
      end if;
      continue;
    end if;

    if resp.status_code between 200 and 299 then
      update notifications
         set status = 'sent', sent_at = now(), error = null,
             provider_message_id = resp.content::jsonb ->> 'id'
       where id = r.id;
      n_sent := n_sent + 1;
    else
      update notifications
         set status = 'failed', failed_at = now(),
             error = coalesce(resp.error_msg,
                              'HTTP ' || coalesce(resp.status_code::text, '?')
                              || ': ' || left(coalesce(resp.content, ''), 300))
       where id = r.id;
      n_failed := n_failed + 1;
    end if;
  end loop;

  return jsonb_build_object('sent', n_sent, 'failed', n_failed);
end $$;

comment on function send_via_resend(text,text,text,text,text) is
  'Posts one email through Resend and returns the pg_net request id. '
  'net.http_post is schema-qualified: pg_net keeps its objects in schema net '
  'on both local and hosted, whatever schema the extension is registered '
  'against, so this must never rely on search_path to find it.';
