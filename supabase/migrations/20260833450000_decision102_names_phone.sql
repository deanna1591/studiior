-- Decision 102 — one name stays one name, one phone one account; Decision 30
-- amendment (the core-only free class picker chooses its line); and the
-- Decision 103 note (member_bootstrap carries free_first_core_only for the
-- picker). One name given anywhere a person is created or claims an account is
-- the first name, and the last name is left empty: nothing copies the first
-- name into the last name. A phone number belongs to one member per studio,
-- enforced by a check in the two phone writers (reason phone_taken). Existing
-- members whose first and last name are identical are corrected once here.
--
-- STEP 0 refinement: the newest claim_member_account (Decision 98) is the invite
-- path and reuses the existing member row, so it never splits a name and is NOT
-- re-issued. The two paths that create a member from a single full_name and copy
-- today are claim_member_by_email (self-signup) and add_walk_in.
--
-- creates: name_last_part(text), mask_email(text), member_set_phone(uuid, text)
-- re-issues: claim_member_by_email(uuid), add_walk_in(uuid, text, text, text), book_guest(uuid, text, text, text), import_commit(uuid), same_person_match(uuid, uuid), staff_set_member_phone(uuid, text), member_bootstrap(text)

-- 1. name_last_part — the text after the first space, or '' for one word. The
-- one definition of "the rest of the name"; claim_member_by_email reads it.
create or replace function name_last_part(p text) returns text
  language sql immutable set search_path = public as $$
  select case when position(' ' in btrim(coalesce(p, ''))) > 0
              then btrim(substring(btrim(p) from position(' ' in btrim(p)) + 1))
              else '' end;
$$;
revoke execute on function name_last_part(text) from public, anon;
grant  execute on function name_last_part(text) to authenticated, service_role;

-- 2. mask_email — first character, then the domain: "d…@gmail.com". For the
-- phone_taken refusal, which names the other account by a masked email.
create or replace function mask_email(p text) returns text
  language sql immutable set search_path = public as $$
  select regexp_replace(coalesce(p, ''), '(.).*@', '\1…@');
$$;
revoke execute on function mask_email(text) from public, anon;
grant  execute on function mask_email(text) to authenticated, service_role;

-- 3. claim_member_by_email — re-issued from 20260831830000 with the split rule.
-- The last name is name_last_part(full_name): empty for one word, never a copy.
create or replace function claim_member_by_email(p_studio_id uuid) returns member_claim
language plpgsql security definer set search_path = public as $$
declare
  u_email     text;
  u_confirmed timestamptz;
  u_fullname  text;
  m           members%rowtype;
  s           studios%rowtype;
  v_new       uuid;
  v_fn        text;
begin
  if auth.uid() is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  select email, email_confirmed_at, coalesce(raw_user_meta_data ->> 'full_name', '')
    into u_email, u_confirmed, u_fullname
    from auth.users where id = auth.uid();
  if u_email is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  if u_confirmed is null then
    return (null, null, null, null, 'email_not_verified')::member_claim;
  end if;

  select * into s from studios where id = p_studio_id and status = 'active';
  if not found then
    return (null, null, null, null, 'no_such_studio')::member_claim;
  end if;

  insert into profiles (id, email, full_name)
  values (auth.uid(), u_email, u_fullname)
  on conflict (id) do nothing;

  select * into m from members
   where studio_id = p_studio_id and user_id = auth.uid();
  if found then
    return (auth.uid(), m.id, s.slug, u_email, null)::member_claim;
  end if;

  select * into m from members
   where studio_id = p_studio_id and lower(email) = lower(u_email);

  if found then
    if m.user_id is not null then
      return (null, null, null, null, 'already_claimed')::member_claim;
    end if;
    update members set user_id = auth.uid() where id = m.id;
    return (auth.uid(), m.id, s.slug, u_email, null)::member_claim;
  end if;

  -- No match: a genuinely new person. Decision 102 — one name given is the
  -- first name and the last name is left empty, never copied.
  v_fn := btrim((select coalesce(full_name, '') from profiles where id = auth.uid()));
  insert into members (studio_id, user_id, first_name, last_name, email,
                       status, joined_on, source)
  values (p_studio_id, auth.uid(),
          coalesce(nullif(split_part(v_fn, ' ', 1), ''), 'New'),
          name_last_part(v_fn),
          u_email, 'lead', current_date, 'self_signup')
  returning id into v_new;

  return (auth.uid(), v_new, s.slug, u_email, null)::member_claim;
end $$;
revoke execute on function claim_member_by_email(uuid) from public, anon;
grant  execute on function claim_member_by_email(uuid) to authenticated, service_role;

-- 4. same_person_match — re-issued (Decision 102 empty-last rule). A name match
-- only fires when BOTH members have a non-empty last name, so an empty last name
-- never matches on first name alone; an empty-last member matches only by phone.
create or replace function same_person_match(p_studio_id uuid, p_member_id uuid)
returns setof uuid
language sql stable security definer set search_path = public as $$
  with me as (
    select m.id, m.studio_id,
           btrim(coalesce(m.last_name, '')) as ln,
           normalise_name(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')) as nn,
           normalise_phone(m.phone, s.country) as np
      from members m join studios s on s.id = m.studio_id
     where m.id = p_member_id)
  select o.id
    from members o
    join me on o.studio_id = me.studio_id
    join studios s on s.id = o.studio_id
   where o.id <> me.id
     and o.deleted_at is null
     and (
       (me.nn is not null
          and me.ln <> ''
          and btrim(coalesce(o.last_name, '')) <> ''
          and normalise_name(coalesce(o.first_name, '') || ' ' || coalesce(o.last_name, '')) = me.nn)
       or (me.np is not null
          and normalise_phone(o.phone, s.country) = me.np));
$$;
revoke execute on function same_person_match(uuid, uuid) from public, anon, authenticated;
grant  execute on function same_person_match(uuid, uuid) to service_role;

-- 5. staff_set_member_phone — re-issued (Decision 102 phone_taken). A number
-- already on another live member of the studio is refused before the write.
create or replace function staff_set_member_phone(p_member_id uuid, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_country text;
  v_norm text;
  v_other members%rowtype;
  v_staff_first text;
begin
  select * into v_member from members where id = p_member_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_member.studio_id), false) or is_service_context()) then
    raise exception 'only the desk and up edit contact details' using errcode = 'PT403';
  end if;
  select country into v_country from studios where id = v_member.studio_id;
  v_norm := normalise_phone(p_phone, v_country);
  if nullif(btrim(coalesce(v_norm, '')), '') is null
     or (v_country = 'PH' and v_norm !~ '^\+639[0-9]{9}$')
     or (coalesce(v_country,'') <> 'PH'
         and length(regexp_replace(coalesce(v_norm,''), '[^0-9]', '', 'g')) not between 7 and 15) then
    raise exception 'that does not look like a mobile number' using errcode = 'PT422';
  end if;

  -- Decision 102: a phone belongs to one member per studio. Only when the
  -- number is actually changing, so re-saving the same number (or an existing
  -- shared pair's own number) is never blocked.
  if v_norm is distinct from normalise_phone(v_member.phone, v_country) then
    select * into v_other from members o
     where o.studio_id = v_member.studio_id and o.id <> p_member_id
       and o.deleted_at is null
       and normalise_phone(o.phone, v_country) = v_norm
     limit 1;
    if found then
      return jsonb_build_object('ok', false, 'reason', 'phone_taken',
        'other_member_id', v_other.id,
        'other_name', btrim(v_other.first_name || ' ' || coalesce(nullif(v_other.last_name, ''), '')),
        'masked_email', mask_email(v_other.email));
    end if;
  end if;

  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''), 'the studio');

  update members set phone = v_norm, updated_at = now() where id = p_member_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_member.studio_id, auth.uid(), 'member.phone_changed', 'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'phone', v_norm));

  return jsonb_build_object('ok', true, 'phone', v_norm);
end $$;
revoke execute on function staff_set_member_phone(uuid, text) from public, anon;
grant  execute on function staff_set_member_phone(uuid, text) to authenticated, service_role;

-- 6. member_set_phone — the member's own phone writer (the required-phone sheet
-- and Account -> Your details). Decision 102 phone_taken, before the write, with
-- the masked email of the other account. The member cannot read another member's
-- row under RLS, so this definer returns the masked email for the refusal.
create or replace function member_set_phone(p_member_id uuid, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_country text;
  v_norm text;
  v_other members%rowtype;
begin
  select * into v_member from members
   where id = p_member_id and user_id = auth.uid() and deleted_at is null;
  if not found then raise exception 'that is not your account' using errcode = 'PT403'; end if;
  select country into v_country from studios where id = v_member.studio_id;
  v_norm := normalise_phone(p_phone, v_country);
  if nullif(btrim(coalesce(v_norm, '')), '') is null
     or (v_country = 'PH' and v_norm !~ '^\+639[0-9]{9}$')
     or (coalesce(v_country,'') <> 'PH'
         and length(regexp_replace(coalesce(v_norm,''), '[^0-9]', '', 'g')) not between 7 and 15) then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;

  if v_norm is distinct from normalise_phone(v_member.phone, v_country) then
    select * into v_other from members o
     where o.studio_id = v_member.studio_id and o.id <> p_member_id
       and o.deleted_at is null
       and normalise_phone(o.phone, v_country) = v_norm
     limit 1;
    if found then
      return jsonb_build_object('ok', false, 'reason', 'phone_taken',
        'masked_email', mask_email(v_other.email));
    end if;
  end if;

  update members set phone = v_norm, updated_at = now() where id = p_member_id;
  return jsonb_build_object('ok', true, 'phone', v_norm);
end $$;
revoke execute on function member_set_phone(uuid, text) from public, anon;
grant  execute on function member_set_phone(uuid, text) to authenticated, service_role;

-- 9. add_walk_in — re-issued (no copy of first into last; empty last for one word).
create or replace function add_walk_in(p_occurrence uuid, p_name text, p_email text, p_mobile text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_scope   text;
  v_occ     class_occurrences%rowtype;
  v_set     studio_settings%rowtype;
  v_ser     class_series%rowtype;
  v_s       studios%rowtype;
  v_tz      text;
  v_today   date;
  v_email   text;
  v_key     text;
  v_member  members%rowtype;
  v_new     boolean := false;
  v_first   text;
  v_last    text;
  v_token   text;
  v_claim   text;
  v_elig    jsonb;
  v_cfg_tier guarantee_tier;
  v_open    boolean;
  v_free    int;
  v_seat    text;
  v_booking uuid;
  v_due     int := null;
  -- plan pick (book_class §2.2)
  v_cand    record;
  v_covers  boolean;
  v_pay     payment_source;
  v_membership uuid;
  v_consume boolean := false;
  v_balance int;
  v_ledger  uuid;
  -- booked elsewhere / alternatives
  v_other   record;
  v_alts    jsonb;
  v_class_when text;
  v_ci      jsonb;
  v_checked boolean := false;
  v_ci_reason text := null;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then
    return jsonb_build_object('ok', false, 'reason', v_scope);
  end if;

  select * into v_occ from class_occurrences where id = p_occurrence for update;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select * into v_s   from studios where id = v_occ.studio_id;
  v_tz := v_s.timezone;
  v_today := (now() at time zone v_tz)::date;

  if v_occ.status <> 'scheduled' then
    return jsonb_build_object('ok', false, 'reason', 'class is not open for booking');
  end if;

  v_email := lower(btrim(coalesce(p_email, '')));
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'reason', 'a valid email is needed');
  end if;
  if coalesce(btrim(p_name), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'a name is needed');
  end if;
  v_key := normalize_email_key(v_email);

  -- Match by normalized email in this studio, else create an unclaimed member.
  select * into v_member from members
   where studio_id = v_occ.studio_id and normalize_email_key(email) = v_key
   order by created_at limit 1;

  if not found then
    v_first := split_part(btrim(p_name), ' ', 1);
    v_last  := btrim(substr(btrim(p_name), length(v_first) + 1));
    insert into members (studio_id, first_name, last_name, email, phone, source, status)
    values (v_occ.studio_id, v_first, v_last, v_email, nullif(btrim(coalesce(p_mobile,'')), ''),
            'front_desk', 'active')
    returning * into v_member;
    v_new := true;

    -- Mint the invite token the way create_member_invite does, WITHOUT sending
    -- member_invite (walk_in_welcome carries the claim link instead). Inlined
    -- because create_member_invite guards is_desk_up and the caller is an
    -- instructor.
    v_token := encode(gen_random_bytes(24), 'hex');
    delete from member_invites where member_id = v_member.id and accepted_at is null;
    insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
    values (v_occ.studio_id, v_member.id, v_email,
            encode(digest(v_token, 'sha256'), 'hex'), now() + make_interval(days => 14), auth.uid());
    v_claim := 'https://' || v_s.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/claim/' || v_token;
  end if;

  -- Already in this class?
  if exists (select 1 from bookings
              where occurrence_id = p_occurrence and member_id = v_member.id
                and status in ('booked','attended','pending_payment','waitlisted')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class');
  end if;

  -- A live booking for ANOTHER class today → offer Move here, do not book.
  select b.id as booking_id, o2.name as class_name, o2.starts_at
    into v_other
    from bookings b join class_occurrences o2 on o2.id = b.occurrence_id
   where b.member_id = v_member.id and b.studio_id = v_occ.studio_id
     and b.occurrence_id <> p_occurrence
     and b.status in ('booked','attended')
     and (o2.starts_at at time zone v_tz)::date = v_today
   order by o2.starts_at limit 1;
  if found then
    return jsonb_build_object('ok', false, 'reason', 'booked elsewhere today',
      'booking_id', v_other.booking_id, 'class_name', v_other.class_name,
      'when', fmt_clock(v_other.starts_at, v_tz, coalesce(v_set.time_format,'24h')),
      'member_id', v_member.id, 'new_member', v_new);
  end if;

  -- Capacity.
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence) - occurrence_seats_held(p_occurrence);
  if v_free < 1 then
    select jsonb_agg(jsonb_build_object(
             'occurrence_id', x.id, 'name', x.name, 'start', x.starts_at,
             'seats_left', x.capacity - occurrence_seats_taken(x.id) - occurrence_seats_held(x.id))
             order by x.starts_at)
      into v_alts
      from (select o3.* from class_occurrences o3
             where o3.studio_id = v_occ.studio_id and o3.status = 'scheduled'
               and o3.id <> p_occurrence
               and o3.starts_at > now()
               and (o3.starts_at at time zone v_tz)::date between v_today and v_today + 1
               and month_published(o3.studio_id, o3.starts_at)
               and (not studio_hides_unstaffed(o3.studio_id) or o3.staffing = 'assigned')
               and o3.capacity - occurrence_seats_taken(o3.id) - occurrence_seats_held(o3.id) > 0
             order by o3.starts_at limit 3) x;
    return jsonb_build_object('ok', false, 'reason', 'class is full',
      'alternatives', coalesce(v_alts, '[]'::jsonb), 'member_id', v_member.id, 'new_member', v_new);
  end if;

  -- ---- seat kind: free first class, else a covering plan, else drop-in -------
  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier, case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier, case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  -- The class is open to first-timers iff book_first_free's gates pass.
  v_open := coalesce(v_set.free_first_class_enabled, false)
    and v_occ.free_first_override is distinct from 'closed'
    and (coalesce(v_occ.free_first_override = 'open', false)
         or ((not coalesce(v_set.free_first_core_only, false) or v_cfg_tier = 'core')
             and (v_occ.series_id is null or coalesce(v_ser.free_first_allowed, true))))
    and not (not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence))
    and not (v_set.free_first_seats_per_class is not null
             and (select count(*) from bookings b
                   where b.occurrence_id = p_occurrence and b.status = 'booked'
                     and b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp
                                  where gp.guest_booking_id = b.id and gp.host_member_id is null))
                 >= v_set.free_first_seats_per_class);

  v_elig := free_first_eligibility_run(v_occ.studio_id, v_member.id);

  if v_new then perform set_config('studiior.suppress_booking_email', '1', true); end if;

  if (v_elig ->> 'ok')::boolean and v_open then
    -- A comp free-first seat, written as book_first_free writes it. A walk-in is
    -- checked in at once, so the seat is CONFIRMED (non-provisional).
    v_seat := 'free_first';
    perform set_config('studiior.free_first', '1', true);
    insert into bookings (studio_id, occurrence_id, member_id, status, source,
                          payment_source, provisional, confirmed_at)
    values (v_occ.studio_id, p_occurrence, v_member.id, 'booked', 'front_desk', 'comp', false, now())
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence;
    insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                              occurrence_id, guest_booking_id, status, waiver_signed_at)
    values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
            p_occurrence, v_booking,
            case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
            v_member.waiver_signed_at)
    on conflict (studio_id, normalize_email_key(guest_email)) do update
      set host_member_id   = excluded.host_member_id,
          guest_member_id  = excluded.guest_member_id,
          occurrence_id    = excluded.occurrence_id,
          guest_booking_id = excluded.guest_booking_id,
          status           = excluded.status,
          waiver_signed_at = excluded.waiver_signed_at;
    perform confirm_provisional_seats_run(p_occurrence);
  else
    -- A covering plan with credit (book_class §2.2 pick), else an unpaid drop-in.
    for v_cand in
      select ms.id, ms.credits_remaining, mp.restrictions,
             case when mp.type = 'recurring' and mp.credits_per_period is null and ms.credits_remaining is null then 1
                  when mp.type = 'recurring' and coalesce(ms.credits_remaining,0) > 0 then 2
                  when mp.type in ('class_pack','drop_in','trial') and coalesce(ms.credits_remaining,0) > 0 then 3
                  else 99 end as priority
        from memberships ms join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = v_member.id and ms.studio_id = v_occ.studio_id
         and (ms.status in ('active','trialing')
              or (ms.status = 'past_due'
                  and now() < coalesce(ms.current_period_end, now()) + make_interval(days => v_set.payment_grace_days)))
         and not (ms.freeze_start is not null and ms.freeze_end is not null and v_today between ms.freeze_start and ms.freeze_end)
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority, ms.expires_on asc nulls last, ms.created_at asc
    loop
      exit when v_cand.priority = 99;
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids', v_occ.class_type_id::text));
      if not v_covers then continue; end if;
      v_pay        := case when v_cand.priority in (1,2) then 'membership'::payment_source else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2,3);
      exit;
    end loop;

    if v_pay is null then
      v_pay := 'drop_in';
      v_seat := 'drop_in';
      select price_cents into v_due from membership_plans
       where studio_id = v_occ.studio_id and type = 'drop_in'
         and visibility = 'public' and status = 'active'
       order by price_cents asc limit 1;
    else
      v_seat := 'plan';
    end if;

    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
    values (v_occ.studio_id, p_occurrence, v_member.id, 'booked', 'front_desk', v_pay,
            case when v_pay in ('membership','class_pack') then v_membership end)
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence;

    if v_consume then
      select coalesce(sum(delta), 0) into v_balance from credit_ledger
       where studio_id = v_occ.studio_id and member_id = v_member.id;
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 booking_id, balance_after, expires_at, actor_user_id)
      select v_occ.studio_id, v_member.id, v_membership, -1, 'booking', v_booking, v_balance - 1,
             case when ms.expires_on is not null then (ms.expires_on + 1)::timestamp at time zone v_tz end,
             auth.uid()
        from memberships ms where ms.id = v_membership
      returning id into v_ledger;
      update memberships set credits_remaining = credits_remaining - 1 where id = v_membership;
      update bookings set credit_entry_id = v_ledger where id = v_booking;
    end if;
  end if;

  -- Checked in at once (method 'instructor'). The §8 window + waiver triggers
  -- fire; if they refuse (window shut, waiver unsigned) the seat stands and the
  -- result says it was not checked in.
  begin
    v_ci := record_check_in(v_booking, 'instructor');
    v_checked := coalesce((v_ci ->> 'ok')::boolean, false);
    if not v_checked then v_ci_reason := v_ci ->> 'reason'; end if;
  exception when others then
    v_checked := false; v_ci_reason := 'check-in not available yet';
  end;

  -- Email. A new member → one combined walk_in_welcome (the booking email was
  -- suppressed above). An existing member → the normal booking email from the
  -- insert trigger; nothing extra here.
  if v_new then
    v_class_when := to_char(v_occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, ')
                    || fmt_clock(v_occ.starts_at, v_tz, coalesce(v_set.time_format,'24h'));
    perform queue_notification(v_occ.studio_id, v_member.id, 'walk_in_welcome',
      jsonb_build_object('claim_url', v_claim, 'class_name', v_occ.name,
        'class_when', v_class_when,
        'due_line', case when v_seat = 'drop_in' and v_due is not null
                         then 'Pay ' || fmt_money(v_due, v_s.currency) || ' at the desk today.' else '' end),
      'walk_in_welcome:' || v_booking);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'member_id', v_member.id,
    'seat', v_seat, 'due_cents', v_due, 'new_member', v_new,
    'checked_in', v_checked, 'checkin_reason', v_ci_reason);
end $$;
revoke execute on function add_walk_in(uuid, text, text, text) from public, anon;
grant  execute on function add_walk_in(uuid, text, text, text) to authenticated, service_role;

-- 10. book_guest — re-issued (empty last name, not the dash placeholder).
CREATE OR REPLACE FUNCTION public.book_guest(p_occurrence_id uuid, p_guest_email text, p_guest_first text, p_guest_last text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_host   members%rowtype;
  v_studio studios%rowtype;
  v_actor  uuid := auth.uid();
  v_email  text := lower(btrim(p_guest_email));
  v_elig   jsonb;
  v_host_booking  uuid;
  v_guest         uuid;
  v_guest_booking uuid;
  v_need   int;
  v_free   int;
  v_res    book_class_result;
  v_token  text;
  v_pass   uuid;
  v_url    text;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- The host is the caller's own member row in this studio (member-driven, §26).
  select * into v_host from members
   where studio_id = v_occ.studio_id and user_id = v_actor;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 48: an unstaffed hidden class is closed to NEW bookings — a guest
  -- is one, so a member cannot bring a guest into a class nobody is teaching.
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;

  -- Eligibility (enabled, email, one-at-a-time, free-once). No writes yet.
  v_elig := guest_pass_eligibility(v_occ.studio_id, v_host.id, p_guest_email);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  -- Decision 98: one free class per person. A guest invite is name-only (no phone
  -- at invite). Refuse if the name matches an existing member who has had a free class.
  if normalise_name(coalesce(p_guest_first, '') || ' ' || coalesce(p_guest_last, '')) is not null
     and exists (
       select 1 from members m
        where m.studio_id = v_occ.studio_id and m.deleted_at is null
          and normalise_name(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, ''))
              = normalise_name(coalesce(p_guest_first, '') || ' ' || coalesce(p_guest_last, ''))
          and member_has_had_free(m.studio_id, m.id)) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  -- Capacity, under the lock. A guest never takes a seat the host didn't also
  -- take: if the host is not already booked we need TWO seats, else one. Held
  -- waitlist seats (§4.2) are not available to a guest either.
  select id into v_host_booking from bookings
   where occurrence_id = p_occurrence_id and member_id = v_host.id
     and status in ('booked','attended','no_show','pending_payment');
  v_need := case when v_host_booking is null then 2 else 1 end;
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < v_need then
    if v_free = 1 and v_need = 2 then
      return jsonb_build_object('ok', false, 'reason', 'only_one_seat');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'class_full');
  end if;

  -- Book the host their own seat if they have none, through the ordinary gate
  -- (their payment, their peak allowance, their eligibility). Must be a real
  -- confirmed seat — a waitlisted or unpaid host is not "in".
  if v_host_booking is null then
    v_res := book_class(p_occurrence_id, v_host.id, 'member');
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', 'host_' || v_res.failure_reason);
    end if;
    if v_res.status <> 'booked' then
      return jsonb_build_object('ok', false, 'reason', 'host_not_booked');
    end if;
    v_host_booking := v_res.booking_id;
  end if;

  -- The guest is a real member, status 'lead' (Decision 15). Email pre-checked
  -- unique, so the insert is safe against members_email.
  insert into members (studio_id, first_name, last_name, email, status, source)
  values (v_occ.studio_id,
          coalesce(nullif(btrim(p_guest_first), ''), 'Guest'),
          coalesce(nullif(btrim(p_guest_last), ''), ''),
          btrim(p_guest_email), 'lead', 'guest_pass')
  returning id into v_guest;

  -- The free, separate seat: comp, no credit, no membership, no peak. Counts on
  -- the roster like any booking, so booked_count moves with it.
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (v_occ.studio_id, p_occurrence_id, v_guest, 'booked', 'member', 'comp')
  returning id into v_guest_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, host_booking_id, guest_booking_id, status)
  values (v_occ.studio_id, v_host.id, v_guest, v_email, p_occurrence_id,
          v_host_booking, v_guest_booking, 'invited')
  returning id into v_pass;

  -- Mint the claim+waiver invite inline: create_member_invite/invite_member both
  -- guard is_desk_up, and the host is a member, so this replicates the minter
  -- here (this function is SECURITY DEFINER). Same hashed, single-use, 14-day token.
  select * into v_studio from studios where id = v_occ.studio_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
  values (v_occ.studio_id, v_guest, btrim(p_guest_email),
          encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days', v_actor);
  v_url := 'https://' || v_studio.slug || '.'
           || coalesce(notification_setting('member_app_domain'), 'studiior.app')
           || '/claim/' || v_token;
  perform queue_notification(v_occ.studio_id, v_guest, 'guest_invite',
    jsonb_build_object('claim_url', v_url, 'host_name', v_host.first_name,
                       'class_name', v_occ.name),
    'guest_invite:' || v_pass);

  -- Decision 30 amendment: the host (and guest) seats may complete a free class's
  -- confirm-at total. A no-op when the class has no provisional free seats.
  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'guest_pass_id', v_pass,
    'guest_member_id', v_guest, 'guest_booking_id', v_guest_booking,
    'host_booking_id', v_host_booking, 'seats_taken', v_need);
end $function$
;

-- 11. import_commit — re-issued (empty last name, not the dash placeholder).
create or replace function public.import_commit(p_import_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  imp     imports%rowtype;
  r       record;
  created int := 0;
  mid     uuid;
  touched uuid[] := '{}';
begin
  select * into imp from imports where id = p_import_id for update;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import' using errcode = 'PT403';
  end if;
  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(imp.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if imp.status <> 'dry_run_complete' then
    raise exception 'run the dry run first — this import is %', imp.status
      using errcode = 'PT409',
            hint = 'Nothing is committed until the owner has seen what will happen.';
  end if;

  for r in select * from import_rows
            where import_id = p_import_id and status = 'ok' order by row_number
  loop
    if imp.type = 'members' then
      insert into members (studio_id, first_name, last_name, email, phone,
                           joined_on, status, waiver_signed_at)
      values (imp.studio_id,
              coalesce(nullif(r.normalized ->> 'first_name', ''), '—'),
              coalesce(nullif(r.normalized ->> 'last_name', ''), ''),
              lower(r.normalized ->> 'email'),
              nullif(r.normalized ->> 'phone', ''),
              coalesce((r.normalized ->> 'joined_on')::date, current_date),
              coalesce(import_member_status(r.normalized ->> 'status'), 'active'),
              (r.normalized ->> 'waiver_signed_at')::timestamptz)
      returning id into mid;

      update import_rows set entity_table = 'members', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    elsif imp.type = 'memberships' then
      insert into memberships (studio_id, member_id, plan_id, status, price_cents,
                               currency, starts_on, expires_on, credits_remaining)
      select imp.studio_id, m.id, p.id,
             coalesce(import_membership_status(r.normalized ->> 'status'), 'active'),
             -- §7.1: the price is snapshotted at purchase. An import carries
             -- what they actually paid when it is in the file, and falls back
             -- to today's plan price only when it is not.
             coalesce((r.normalized ->> 'price_cents')::int, p.price_cents),
             p.currency,
             coalesce((r.normalized ->> 'starts_on')::date, current_date),
             (r.normalized ->> 'expires_on')::date,
             coalesce((r.normalized ->> 'credits_remaining')::int,
                      p.credits, p.credits_per_period)
        from members m, membership_plans p
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
         and p.studio_id = imp.studio_id
         and lower(p.name) = lower(r.normalized ->> 'plan')
      returning id into mid;

      update import_rows set entity_table = 'memberships', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    else  -- attendance
      -- No occurrence and no booking: the class this visit belonged to is not
      -- in the export and inventing one would put thousands of classes that
      -- never ran into the calendar. import_id carries the provenance and
      -- exempts the row from the §8 check-in window, which is about people
      -- arriving, not about recording that they did. method 'import' (Decision
      -- 35) so 'staff' means a human at the desk.
      insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                             checked_in_at, method, import_id)
      select imp.studio_id, null, m.id, null,
             (r.normalized ->> 'attended_at')::timestamptz, 'import', p_import_id
        from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
      returning id, member_id into mid, mid;

      select m.id into mid from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email');
      touched := touched || mid;

      update import_rows set entity_table = 'check_ins',
                             entity_id = (select ci.id from check_ins ci
                                           where ci.import_id = p_import_id
                                             and ci.member_id = mid
                                           order by ci.created_at desc limit 1),
                             status = 'committed'
       where id = r.id;
    end if;

    created := created + 1;
  end loop;

  update imports set status = 'complete' where id = p_import_id;

  -- Imported attendance changes what every visit-derived number means.
  if imp.type = 'attendance' and array_length(touched, 1) is not null then
    perform recompute_member_stats(imp.studio_id, touched);
    perform refresh_studio_health(imp.studio_id);
  end if;

  return jsonb_build_object('created', created, 'type', imp.type);
end $function$;

-- 7. member_bootstrap — re-issued (drop + recreate, + free_first_core_only for
-- the Decision 30 core-only picker). Byte-for-byte the 20260833440000 body with
-- one column added.
drop function if exists member_bootstrap(text);
create function public.member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text, fee_waived boolean, reservation_credit_cents integer, free_first_core_only boolean)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h'),
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz)),
    not (
      (coalesce(st.desk_pay_mode, 'earned') = 'earned' and m.desk_pay_blocked_at is not null)
      or (coalesce(st.desk_pay_mode, 'earned') = 'first_visit_only'
          and exists (select 1 from bookings bdp
                       where bdp.member_id = m.id and bdp.studio_id = m.studio_id
                         and bdp.payment_source = 'drop_in' and bdp.status <> 'cancelled'))
    ),
    st.payee_notice_name,
    (nullif(btrim(coalesce(m.phone, '')), '') is not null),
    s.country,
    coalesce(st.free_first_reservation_fee_cents, 0),
    s.currency,
    (m.reservation_fee_waived_at is not null),
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null), 0),
    coalesce(st.free_first_core_only, false)
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- 8. One-time name correction. Every live member whose first and last name are
-- identical loses the (copied) last name; one audit row per correction.
do $$
declare r record; n int := 0;
begin
  for r in
    select id, studio_id, first_name, last_name from members
     where deleted_at is null
       and btrim(coalesce(first_name, '')) <> ''
       and lower(btrim(first_name)) = lower(btrim(last_name))
  loop
    update members set last_name = '', updated_at = now() where id = r.id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (r.studio_id, null, 'member.name_corrected', 'members', r.id,
              jsonb_build_object('first_name', r.first_name, 'last_name', r.last_name),
              jsonb_build_object('first_name', r.first_name, 'last_name', ''));
    n := n + 1;
  end loop;
  raise notice 'Decision 102: cleared last name on % members (first = last)', n;
end $$;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
