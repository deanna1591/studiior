-- =============================================================================
-- MIGRATION 015 — a studio cannot be stored with a timezone that isn't real
--
-- The studio timezone governs display and every day boundary, and occurrences
-- are materialised by converting local time to UTC against it (CLAUDE.md).
-- A typo does not fail loudly: "Europe/Pragu" is not a zone, "Europe/Prague"
-- is, and the difference between them is every class time in the studio being
-- silently wrong. Worse, the damage is already in the data by the time anyone
-- notices, because occurrences were generated against the bad value.
--
-- The form now offers a searchable list rather than free text, but a form is
-- not a constraint: the wizard writes studios directly through RLS, an import
-- would not go near either, and provision_studio() is one caller of several.
-- So the rule goes where every writer meets it.
--
-- pg_timezone_names is Postgres's own view over the IANA tzdata it was built
-- with — the same source the application reads through
-- Intl.supportedValuesOf('timeZone'). It carries 1196 names to the browser's
-- ~420 canonical ones (aliases, posix/*, Etc/GMT±N), so the list the form
-- offers is a strict subset and nothing valid is refused.
-- =============================================================================

create function validate_iana_timezone() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.timezone is not null
     and not exists (select 1 from pg_timezone_names where name = new.timezone)
  then
    raise exception '% is not an IANA timezone', new.timezone
      using errcode = 'PT422',
            hint = 'Use an identifier from pg_timezone_names, e.g. Europe/Prague. '
                   'Matching is case-sensitive.';
  end if;
  return new;
end $$;

comment on function validate_iana_timezone() is
  'Refuses a timezone Postgres does not recognise. Attached to every table with '
  'a timezone column, because a bad one is only discovered after occurrences '
  'have been materialised against it.';

create trigger studios_timezone_valid
  before insert or update of timezone on studios
  for each row execute function validate_iana_timezone();

-- Dormant in V1 but written by provision_studio(), and it would drift the same
-- way the day multi-location wakes up (Decision 8).
create trigger locations_timezone_valid
  before insert or update of timezone on locations
  for each row execute function validate_iana_timezone();

revoke execute on function validate_iana_timezone() from public, anon, authenticated, service_role;

-- Currency and country are already width-limited by char(3)/char(2); this is
-- about shape. 'cz' and 'C1' both fit and neither is an ISO code.
alter table studios
  add constraint studios_currency_iso4217 check (currency ~ '^[A-Z]{3}$'),
  add constraint studios_country_iso3166  check (country is null or country ~ '^[A-Z]{2}$');

-- =============================================================================
-- provision_studio(), fixed forward
--
-- Migration 012 has run against the hosted project, so it is history. Same
-- signature, so CREATE OR REPLACE keeps every existing grant. Three new reason
-- codes; everything else is unchanged.
--
-- The trigger above would already refuse a bad zone, but it would do it by
-- raising, and this function's contract is to return a reason rather than throw.
-- Checking here keeps that contract; the trigger is what makes it true for
-- callers that never come through this function.
-- =============================================================================

create or replace function provision_studio(
  p_name        text,
  p_slug        text,
  p_timezone    text,
  p_currency    char(3),
  p_country     char(2),
  p_owner_email text,
  p_valid_days  int default 14
) returns provision_result
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_token  text;
  v_slug   text := lower(btrim(p_slug));
  v_email  text := lower(btrim(p_owner_email));
  v_cur    text := upper(btrim(p_currency));
  v_ctry   text := upper(btrim(p_country));
begin
  if not is_platform_admin() then
    return (null, null, null, 'not_platform_admin')::provision_result;
  end if;

  if v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$' then
    return (null, null, null, 'invalid_slug')::provision_result;
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return (null, null, null, 'invalid_email')::provision_result;
  end if;

  -- Checked before anything is written, so a typo costs nothing.
  if not exists (select 1 from pg_timezone_names where name = btrim(p_timezone)) then
    return (null, null, null, 'invalid_timezone')::provision_result;
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    return (null, null, null, 'invalid_currency')::provision_result;
  end if;
  if v_ctry !~ '^[A-Z]{2}$' then
    return (null, null, null, 'invalid_country')::provision_result;
  end if;

  if exists (select 1 from studios where slug = v_slug) then
    return (null, null, null, 'slug_taken')::provision_result;
  end if;

  insert into studios (name, slug, timezone, currency, country, status)
  values (btrim(p_name), v_slug, btrim(p_timezone), v_cur, v_ctry, 'provisioning')
  returning id into v_studio;

  insert into studio_settings (studio_id) values (v_studio);

  insert into locations (studio_id, name, timezone, is_primary)
  values (v_studio, btrim(p_name), btrim(p_timezone), true);

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into studio_invites (studio_id, email, token_hash, expires_at, created_by)
  values (v_studio, v_email,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => greatest(p_valid_days, 1)),
          auth.uid());

  return (v_studio, v_token, now() + make_interval(days => greatest(p_valid_days, 1)), null)::provision_result;
end $$;

revoke execute on function provision_studio(text,text,text,char,char,text,int) from public, anon;
grant execute on function provision_studio(text,text,text,char,char,text,int)
  to authenticated, service_role;

comment on type provision_result is
  'Result of provision_studio(). failure_reason codes: not_platform_admin, '
  'invalid_slug, invalid_email, invalid_timezone, invalid_currency, '
  'invalid_country, slug_taken.';
