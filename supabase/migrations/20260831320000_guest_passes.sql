-- Decision 26 — a member may bring a guest, and the guest's first class is free.
-- Optional per studio, OFF by default (guest_passes_enabled), the same rule as
-- Decisions 24/25 and challenges: a studio that never turns it on sees no trace.
--
-- The acquisition mechanic: a member invites a friend, the friend's first class
-- costs nothing, and a real member record exists by the time they want to book
-- again — so buying a pack is a purchase, not a signup.
--
-- Shape of the rules, all enforced below:
--   FREE ONCE EVER, keyed on email — a unique index on guest_passes, plus a
--     check against `members` so a returning/lapsed member is not "new".
--   THE GUEST BOOKS THE HOST'S CLASS — book_guest ensures the host holds a real
--     seat and gives the guest a second seat in the SAME occurrence, so a guest
--     never takes a seat the host didn't also take (a full class needs two).
--   ONE GUEST AT A TIME — a partial unique index while a pass is live.
--   THE GUEST SEAT IS FREE AND SEPARATE — payment_source 'comp', no credit, no
--     peak allowance (it never touches the host's membership).
--   HOST CANCELS -> GUEST STANDS, and the guest is told (a trigger).
--   WAIVER BEFORE THE CLASS -> unsigned blocks CHECK-IN (a trigger on check_ins),
--     and the guest signs it in the app (sign_waiver, self-serve).
--   THE ACCOUNT — the guest is a real member with status 'lead' (Decision 15),
--     invited to claim, ordinary thereafter except that their free class is spent.

-- The DOOR, off by default. Governs the member-app guest affordance and every
-- staff guest surface; turning it off never rug-pulls a guest already booked,
-- because the guest booking is an ordinary booking that stands on its own.
alter table studio_settings
  add column if not exists guest_passes_enabled boolean not null default false;

-- The ledger. One row per invitation; the guest's own member row is the account.
create table guest_passes (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  host_member_id   uuid not null references members on delete cascade,
  guest_member_id  uuid not null references members on delete cascade,
  guest_email      text not null,                 -- lower()ed: the free-once key
  occurrence_id    uuid not null references class_occurrences on delete cascade,
  host_booking_id  uuid references bookings on delete set null,
  guest_booking_id uuid references bookings on delete set null,
  -- invited: booked, waiver unsigned. confirmed: waiver signed. attended: came
  -- (frees the host to invite again). cancelled: guest booking gone.
  status           text not null default 'invited'
                     check (status in ('invited','confirmed','attended','cancelled')),
  waiver_signed_at timestamptz,
  created_at       timestamptz not null default now()
);

-- FREE ONCE EVER at a studio, keyed on email. A second free class for the same
-- address is refused at the index even if the app forgets to check.
create unique index guest_passes_one_per_email
  on guest_passes (studio_id, lower(guest_email));

-- ONE GUEST AT A TIME: a host cannot invite another while one is still live
-- (invited or confirmed). Attending or cancelling frees them.
create unique index guest_passes_one_live_per_host
  on guest_passes (studio_id, host_member_id)
  where status in ('invited','confirmed');

create index guest_passes_occurrence on guest_passes (occurrence_id);
create index guest_passes_guest       on guest_passes (guest_member_id);

alter table guest_passes enable row level security;

-- The host and the guest may read their own pass; desk-up reads all. Every WRITE
-- is through the SECURITY DEFINER functions below (owned by postgres, so they
-- bypass RLS) — there is no client write grant.
create policy guest_passes_read on guest_passes for select using (
  coalesce(is_desk_up(studio_id), false)
  or exists (select 1 from members m
              where m.user_id = auth.uid()
                and m.id in (guest_passes.host_member_id, guest_passes.guest_member_id))
);

grant select on guest_passes to authenticated;

-- ---------------------------------------------------------------------------
-- Notification templates. html_body is NOT NULL and placeholders are single
-- braces, substituted by key in render_notification (checked against member_invite).
-- ---------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('guest_invite', '{host_name} booked you a free class at {studio_name}',
 E'Hi,\n\n{host_name} has booked you a free class — {class_name} — at {studio_name}.\n\nTwo quick things before you come: set up your account and sign the waiver in the app. Your place is confirmed once the waiver is signed.\n\n{claim_url}\n\nSee you there,\n{studio_name}',
 E'<p>Hi,</p><p><strong>{host_name}</strong> has booked you a free class — <strong>{class_name}</strong> — at {studio_name}.</p><p>Set up your account and sign the waiver in the app. Your place is confirmed once the waiver is signed.</p><p><a href="{claim_url}">Set up your account</a></p>',
 'Decision 26. Sent to a guest a member brought. Claim + waiver; no settings link (no account yet).'),
('guest_host_cancelled', 'Your class at {studio_name} — {host_name} cancelled, but you can still come',
 E'Hi {first_name},\n\n{host_name} had to cancel their spot in {class_name}, but YOUR place still stands — please come along.\n\nSee you there,\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{host_name} had to cancel their spot in <strong>{class_name}</strong>, but <strong>your place still stands</strong> — please come along.</p>',
 'Decision 26. The host cancelled; the guest booking stands and the guest is told.');

-- guest emails are always-send (a guest has no preferences row and no settings
-- screen). Also added to render_notification's always list below.
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_joined'      then p.challenge_email
    when 'challenge_milestone'   then p.challenge_email
    when 'challenge_completed'   then p.challenge_email
    when 'challenge_ending_soon' then p.challenge_email
    when 'challenge_opening'     then p.challenge_email
    else true
  end;
end $$;

-- ---------------------------------------------------------------------------
-- render_notification re-issued (create-or-replace keeps its ACL): guest_invite
-- and guest_host_cancelled join the always-send list, and guest_invite gets the
-- member_invite footer — no settings link, because a guest has no account yet.
-- ---------------------------------------------------------------------------
create or replace function public.render_notification(p_notification_id uuid)
 RETURNS TABLE(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; k text; rule text;
  v_addr text; v_link text; v_contact text;
  v_always boolean; v_foot_txt text; v_foot_html text;
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select * into m from members where id = n.member_id;

  -- A notification can be addressed to a person at the studio rather than to a
  -- member — platform billing is the first of those, and it has to reach the
  -- owner rather than somebody who books classes. The renderer had only ever
  -- looked in `members`, so this branch is what a staff-addressed row needs to
  -- render at all rather than as an email to nobody.
  v_is_staff := n.recipient_type = 'staff';
  if v_is_staff then
    select coalesce(ss.email, pr.email), coalesce(pr.full_name, ss.email)
      into v_staff_email, v_staff_name
      from studio_staff ss
      left join profiles pr on pr.id = ss.user_id
     where ss.user_id = n.user_id and ss.studio_id = n.studio_id
     limit 1;
  end if;
  select * into s from studios where id = n.studio_id;
  if t.key is null then
    raise exception 'no template %', n.template_key using errcode = 'PT404';
  end if;

  v_sub  := t.subject;
  v_txt  := t.text_body;
  v_html := t.html_body;

  for k in select jsonb_object_keys(n.payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(n.payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    -- falls through to the same replace below, with m.first_name null-safe
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
  end loop;

  -- Neutral, not Studiior's lime. A studio that has not picked an accent gets
  -- grey in its own mail rather than another company's brand colour.
  rule := coalesce(s.accent_color, '#78716C');

  -- locations.address is jsonb with no fixed shape (data model line 101), so
  -- assigning it straight into a text variable put a raw JSON object in the
  -- footer of a real email: {"city": "Prague", "line1": ...}. Assembled by key,
  -- skipping whatever a given studio has not filled in.
  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''),
           nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''),
           nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  -- A member's email-settings screen means nothing to a studio owner being
  -- told their subscription lapsed, so a staff email points at their billing
  -- screen instead. Offering the member link would be a control that does
  -- nothing for the person reading it.
  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/settings';
  end if;

  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone), '');

  -- §12: three events have no opt-out, and staff_message is a person writing to
  -- one member. Saying "always sends" is what stops the footer being a lie.
  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 -- An invite cannot be turned off, and the
                                 -- person reading it has no settings screen
                                 -- to reach yet — offering them one would be
                                 -- a control that does nothing.
                                 'member_invite',
                                 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact,
    v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         -- An invite gets NO settings link: the person reading it has no
         -- account, so the screen it points at would refuse them. A control
         -- that does nothing is worse than no control.
         when n.template_key in ('member_invite', 'guest_invite')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact,
    v_addr,
    case when v_is_staff
         then '<a href="' || v_link || '" style="color:#57534E">Your billing</a>'
         when n.template_key in ('member_invite', 'guest_invite')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#57534E">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#57534E">Choose which emails you get</a>' end);

  return query select
    coalesce(v_staff_email, m.email),
    s.name,              -- the from-name is the studio, never Studiior
    s.contact_email,     -- null means no reply-to header, not a fake one
    v_sub,
    v_txt || E'\n\n--\n' || v_foot_txt,
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E;max-width:520px;margin:0 auto;padding:24px">'
      || case when s.logo_url is not null
              then '<img src="' || s.logo_url || '" alt="' || s.name
                   || '" width="40" height="40" style="border-radius:6px;display:block;margin-bottom:16px">'
              else '<div style="font-weight:600;font-size:17px;margin-bottom:16px">' || s.name || '</div>'
         end
      || '<div style="height:3px;width:44px;background:' || rule || ';margin-bottom:20px"></div>'
      || v_html
      || '<p style="color:#78716C;font-size:13px;line-height:18px;margin-top:28px;'
      || 'border-top:1px solid #E7E5E4;padding-top:14px">' || v_foot_html || '</p></div>';
end $function$

;

-- -----------------------------------------------------------------------------
-- Telling the studio and the instructor
--
-- Staff-addressed rows go in directly with recipient_type = 'staff', which
-- migration 046 taught render_notification() to resolve. queue_notification()
-- is member-only and checks member preferences, neither of which applies here.
-- -----------------------------------------------------------------------------
/**
 * The login behind an instructor, if they have one.
 *
 * instructors.staff_id references studio_staff(id) — NOT a user id. Passing it
 * straight to a notification addresses a user that does not exist, which is
 * exactly the bug this function exists to stop being written three times.
 */
create or replace function instructor_user_id(p_instructor_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select ss.user_id
    from instructors i
    join studio_staff ss on ss.id = i.staff_id
   where i.id = p_instructor_id and ss.status = 'active'
$$;


-- ---------------------------------------------------------------------------
-- guest_pass_eligibility — the same checks the UI previews and book_guest runs.
-- Returns {ok} or {ok:false, reason:<code>}; capacity is NOT here (it needs the
-- lock and the host's own booking state), it is in book_guest.
-- ---------------------------------------------------------------------------
create function guest_pass_eligibility(p_studio_id uuid, p_host_member_id uuid, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not coalesce((select guest_passes_enabled from studio_settings where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;
  if v_email = '' or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_email');
  end if;
  -- One guest at a time.
  if exists (select 1 from guest_passes
              where host_member_id = p_host_member_id and status in ('invited','confirmed')) then
    return jsonb_build_object('ok', false, 'reason', 'have_active_guest');
  end if;
  -- Free once ever, keyed on email: a prior guest (even if that lead was since
  -- deleted) is refused as "already had a free class"; any other existing member
  -- is refused as "already a member". Distinct sentences at the call site.
  if exists (select 1 from guest_passes where studio_id = p_studio_id and lower(guest_email) = v_email) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;
  if exists (select 1 from members where studio_id = p_studio_id and lower(email) = v_email) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- book_guest — the host brings a guest. Books the host too if they are not
-- already in (so "two free seats" is exact), creates the guest as a 'lead'
-- member with a free comp seat, mints a claim+waiver invite, and records the
-- pass. One transaction: any failure after the host is booked raises and rolls
-- the whole thing back, so a host is never left booked with no guest.
-- ---------------------------------------------------------------------------
create function book_guest(p_occurrence_id uuid, p_guest_email text,
                           p_guest_first text, p_guest_last text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
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

  -- Eligibility (enabled, email, one-at-a-time, free-once). No writes yet.
  v_elig := guest_pass_eligibility(v_occ.studio_id, v_host.id, p_guest_email);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

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
          coalesce(nullif(btrim(p_guest_last), ''), '—'),
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

  return jsonb_build_object('ok', true, 'guest_pass_id', v_pass,
    'guest_member_id', v_guest, 'guest_booking_id', v_guest_booking,
    'host_booking_id', v_host_booking, 'seats_taken', v_need);
end $$;

-- ---------------------------------------------------------------------------
-- sign_waiver — a member signs their own waiver in the app (self or desk). This
-- is what confirms a guest's place (§26). General beyond guests: waiver_signed_at
-- gates booking (§2.1), and a member with an unsigned waiver can now clear it.
-- ---------------------------------------------------------------------------
create function sign_waiver(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (m.user_id = auth.uid() or coalesce(is_desk_up(m.studio_id), false)) then
    raise exception 'that is not your waiver to sign' using errcode = 'PT403';
  end if;
  update members set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = p_member_id;
  -- Confirm any live guest pass for this member.
  update guest_passes set status = 'confirmed', waiver_signed_at = now()
   where guest_member_id = p_member_id and status = 'invited';
  return jsonb_build_object('ok', true, 'waiver_signed', true);
end $$;

-- ---------------------------------------------------------------------------
-- Keep the pass in step with the bookings it points at.
--   host booking cancelled -> tell the guest, their booking STANDS (§26).
--   guest booking attended  -> pass 'attended' (frees the host to invite again).
--   guest booking cancelled -> pass 'cancelled'.
-- ---------------------------------------------------------------------------
create function tg_guest_pass_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare gp guest_passes%rowtype;
begin
  if new.status is not distinct from old.status then return new; end if;

  -- Host cancelled: the guest keeps their seat and is told their friend cancelled.
  if new.status in ('cancelled','late_cancelled') and old.status not in ('cancelled','late_cancelled') then
    select * into gp from guest_passes
     where host_booking_id = new.id and status in ('invited','confirmed');
    if found then
      perform queue_notification(gp.studio_id, gp.guest_member_id, 'guest_host_cancelled',
        jsonb_build_object('host_name', (select first_name from members where id = gp.host_member_id),
                           'class_name', (select name from class_occurrences where id = gp.occurrence_id)),
        'guest_host_cancelled:' || gp.id);
    end if;
  end if;

  -- Guest attended, or the guest booking went away.
  select * into gp from guest_passes where guest_booking_id = new.id;
  if found then
    if new.status = 'attended' and gp.status in ('invited','confirmed') then
      update guest_passes set status = 'attended' where id = gp.id;
    elsif new.status in ('cancelled','late_cancelled') and gp.status in ('invited','confirmed') then
      update guest_passes set status = 'cancelled' where id = gp.id;
    end if;
  end if;

  return new;
end $$;
create trigger tg_guest_pass_sync after update of status on bookings
  for each row execute function tg_guest_pass_sync();

-- ---------------------------------------------------------------------------
-- The waiver gate at CHECK-IN. A guest whose waiver is unsigned by the time they
-- reach the desk is refused, and the desk is told to have them sign in the app.
-- On check_ins, the single choke point for staff, QR, import and job paths.
-- ---------------------------------------------------------------------------
create function enforce_guest_waiver() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from guest_passes gp
      join members m on m.id = gp.guest_member_id
     where gp.guest_member_id = new.member_id
       and gp.occurrence_id  = new.occurrence_id
       and m.waiver_signed_at is null
  ) then
    raise exception 'this guest has not signed the waiver yet'
      using errcode = 'PT422',
            hint = 'Ask them to sign it in the app, then check them in.';
  end if;
  return new;
end $$;
create trigger enforce_guest_waiver before insert on check_ins
  for each row execute function enforce_guest_waiver();

-- ---------------------------------------------------------------------------
-- Reporting. The number that says whether this works: how many guests converted
-- to paying members. Converted is DERIVED — the guest member holds any membership.
-- ---------------------------------------------------------------------------
create function guest_pass_report(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers read the guest report' using errcode = 'PT403';
  end if;
  return (
    select jsonb_build_object(
      'total',     count(*),
      'attended',  count(*) filter (where gp.status = 'attended'),
      'pending',   count(*) filter (where gp.status in ('invited','confirmed')),
      'converted', count(*) filter (where exists (
                     select 1 from memberships ms where ms.member_id = gp.guest_member_id)),
      'conversion_rate', case when count(*) filter (where gp.status = 'attended') = 0 then null
        else round(100.0 * count(*) filter (where gp.status = 'attended'
               and exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
             / count(*) filter (where gp.status = 'attended')) end)
    from guest_passes gp where gp.studio_id = p_studio_id);
end $$;

-- The dashboard KPI, in the dashboard_challenge_kpi shape: null (and so the card
-- is absent) when the studio does not run guest passes or has never had a guest.
create function dashboard_guest_kpi(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_total int; v_conv int;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  if not coalesce((select guest_passes_enabled from studio_settings where studio_id = p_studio_id), false) then
    return null;
  end if;
  select count(*),
         count(*) filter (where exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
    into v_total, v_conv
    from guest_passes gp where gp.studio_id = p_studio_id;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'key', 'guest_conversion',
    'label', 'Guests converted',
    'state', case when v_conv = 0 then 'empty' else 'ok' end,
    'kind', 'count',
    'value', v_conv,
    'sub', 'of ' || v_total || ' guest' || case when v_total = 1 then '' else 's' end,
    'href', '/members',
    'empty_hint', 'None have bought a plan yet.');
end $$;

-- ---------------------------------------------------------------------------
-- Grants. book_guest, sign_waiver, guest_pass_eligibility and both reports are
-- guarded inside and callable by a signed-in client; the two triggers by nobody.
-- ---------------------------------------------------------------------------
revoke execute on function tg_guest_pass_sync()  from public, anon, authenticated;
revoke execute on function enforce_guest_waiver() from public, anon, authenticated;
revoke execute on function book_guest(uuid, text, text, text)           from public, anon;
revoke execute on function guest_pass_eligibility(uuid, uuid, text)     from public, anon;
revoke execute on function sign_waiver(uuid)                            from public, anon;
revoke execute on function guest_pass_report(uuid)                      from public, anon;
revoke execute on function dashboard_guest_kpi(uuid)                    from public, anon;
grant  execute on function book_guest(uuid, text, text, text)           to authenticated;
grant  execute on function guest_pass_eligibility(uuid, uuid, text)     to authenticated;
grant  execute on function sign_waiver(uuid)                            to authenticated;
grant  execute on function guest_pass_report(uuid)                      to authenticated, service_role;
grant  execute on function dashboard_guest_kpi(uuid)                    to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Surface guest_passes_enabled to the member app. studio_member_settings() is
-- the member-facing subset of studio_settings (a member cannot read the table),
-- and the "bring a guest" affordance needs the flag. A RETURNS TABLE cannot gain
-- a column through create-or-replace, so it is dropped and re-granted.
-- ---------------------------------------------------------------------------
drop function if exists studio_member_settings(uuid);
create function studio_member_settings(p_studio_id uuid)
returns table(checkin_opens_minutes_before integer, checkin_closes_minutes_after integer,
              cancellation_cutoff_minutes integer, booking_cutoff_minutes integer,
              waitlist_enabled boolean, week_starts_on integer, guest_passes_enabled boolean)
language sql stable security definer set search_path = public as $$
  select s.checkin_opens_minutes_before, s.checkin_closes_minutes_after,
         s.cancellation_cutoff_minutes, s.booking_cutoff_minutes,
         s.waitlist_enabled, s.week_starts_on, s.guest_passes_enabled
    from studio_settings s
   where s.studio_id = p_studio_id
     and (p_studio_id in (select auth_member_studios())
          or p_studio_id in (select auth_staff_studios()))
$$;
revoke execute on function studio_member_settings(uuid) from public, anon;
grant  execute on function studio_member_settings(uuid) to authenticated, service_role;
