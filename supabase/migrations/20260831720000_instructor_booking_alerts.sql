-- =============================================================================
-- 167  Decision 33 amendment (Deanna's decision): the instructor per-booking
--      email opt-in becomes a per-tenant switch, and coalesces per class.
-- =============================================================================
-- For Reform, an instructor must ALWAYS know when a booking lands on or leaves
-- their class — not the individual's choice to decline. So the per-instructor
-- opt-in (instructors.email_each_booking + the /instructor/me toggle) is removed
-- and replaced by studio_settings.instructor_booking_alerts (off by default
-- product-wide; the all_off canary stays at zero on defaults). And the alert
-- coalesces: ONE notice per class per 15-minute window, deduped on the class +
-- window and scheduled for the window's end, so a second change inside it
-- UPDATES the pending notice rather than adding one.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The per-tenant switch. Off by default like every opt-in.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists instructor_booking_alerts boolean not null default false;
comment on column studio_settings.instructor_booking_alerts is
  'Decision 33 amendment. When on, the assigned instructor is emailed a coalesced '
  'per-class notice (15-min window) whenever a booking lands on or leaves their '
  'class. No per-instructor opt-out. Off by default.';

-- -----------------------------------------------------------------------------
-- 2. queue_booking_notifications loses the per-booking instructor email (now the
--    coalesced alert below). Re-issued from migration 163 (the newest, via
--    scripts/newest-definition.sh) with only that block removed.
-- -----------------------------------------------------------------------------
create or replace function queue_booking_notifications(p_booking_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  -- Decision 30: this booking is the free first class iff it is comp AND the
  -- shared ledger holds a host-null pass for it. One extra line, same template.
  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
        jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                           'manage_link', v_manage,
                           'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                           'booking_id', b.id, 'occurrence_id', o.id),
        'booking_confirmed:' || b.id) is not null then n := n + 1; end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  -- (The instructor per-booking email is gone — Decision 33 amendment: it is
  -- now the coalesced per-class alert, tg_instructor_booking_alert, gated on
  -- studio_settings.instructor_booking_alerts, not this per-booking path.)

  return n;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Remove the old opt-in: the writer, then the column.
-- -----------------------------------------------------------------------------
drop function if exists set_email_each_booking(uuid, boolean);
alter table instructors drop column if exists email_each_booking;

-- -----------------------------------------------------------------------------
-- 4. The "what changed" wording, from the accumulated deltas. Immutable.
-- -----------------------------------------------------------------------------
create or replace function change_line_text(p_booked int, p_cancelled int) returns text
language sql immutable as $$
  select case
    when coalesce(p_booked,0) > 0 and coalesce(p_cancelled,0) > 0
      then '+' || p_booked || ' booked, ' || p_cancelled || ' cancelled'
    when coalesce(p_booked,0) > 0 then '+' || p_booked || ' booked'
    when coalesce(p_cancelled,0) > 0 then p_cancelled || ' cancelled'
    else 'updated'
  end
$$;
revoke execute on function change_line_text(int, int) from public, anon;
grant  execute on function change_line_text(int, int) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. The template. first_name resolves to the instructor via render_notification.
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_booking_alert',
 '{class_name} — {change_line}',
 E'Hi {first_name},\n\n{class_name} on {when}.\n{change_line} since the last update — now {headcount} booked{spaces_line}.\n\nSee the roster: {roster_link}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{class_name}</strong> on {when}.</p><p>{change_line} since the last update — now <strong>{headcount}</strong> booked{spaces_line}.</p><p><a href="{roster_link}">See the roster</a></p>',
 'Decision 33 amendment. Coalesced per-class booking alert to the assigned '
 'instructor, one per 15-min window; the delta accumulates and the notice sends '
 'at the window end.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 6. The coalescing writer. ONE notice per class per 15-min window: dedupe on
--    the class + window bucket, schedule for the window end so changes within it
--    accumulate, and on a second change UPDATE the pending notice's payload
--    (delta + current headcount) rather than add a row. Internal.
-- -----------------------------------------------------------------------------
create or replace function queue_instructor_booking_alert(
  p_occurrence_id uuid, p_gained int, p_lost int
) returns void
language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_user uuid; v_bucket bigint; v_dedupe text; v_sched timestamptz;
  v_head int; v_spaces int; v_when text; v_roster text; v_sl text;
  v_nb int; v_nc int; v_change text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return; end if;      -- unassigned => nothing
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.instructor_booking_alerts, false) then return; end if;   -- switch off
  if not month_published(o.studio_id, o.starts_at) then return; end if;       -- Decision 25
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return; end if;                            -- no login, nowhere to send

  select * into s from studios where id = o.studio_id;
  v_bucket := floor(extract(epoch from now()) / 900)::bigint;       -- 15-minute window
  v_dedupe := 'instr_booking_alert:' || o.id || ':' || v_bucket;
  v_sched  := to_timestamp((v_bucket + 1) * 900);                   -- send at window end
  v_head   := occurrence_seats_taken(o.id);                         -- current, includes this change
  v_spaces := greatest(coalesce(o.capacity, 0) - v_head, 0);
  v_when   := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
  v_roster := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/instructor/roster/' || o.id;
  v_sl := case when v_spaces > 0
               then ', ' || v_spaces || ' space' || case when v_spaces = 1 then '' else 's' end || ' left'
               else ' (full)' end;

  -- Accumulate over the window: the prior deltas in the pending notice (0 if none).
  select coalesce((payload ->> 'n_booked')::int, 0), coalesce((payload ->> 'n_cancelled')::int, 0)
    into v_nb, v_nc
    from notifications where dedupe_key = v_dedupe and status = 'scheduled';
  v_nb := coalesce(v_nb, 0) + coalesce(p_gained, 0);
  v_nc := coalesce(v_nc, 0) + coalesce(p_lost, 0);
  v_change := change_line_text(v_nb, v_nc);

  insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (o.studio_id, 'staff', v_user, 'instructor_booking_alert', 'email',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'headcount', v_head,
                             'spaces_line', v_sl, 'change_line', v_change, 'roster_link', v_roster,
                             'occurrence_id', o.id, 'n_booked', v_nb, 'n_cancelled', v_nc),
          v_dedupe, v_sched, 'scheduled')
  on conflict (dedupe_key) do update
    set payload = excluded.payload
    where notifications.status = 'scheduled';
end $$;
revoke execute on function queue_instructor_booking_alert(uuid, int, int) from public, anon, authenticated;
grant  execute on function queue_instructor_booking_alert(uuid, int, int) to service_role;

-- -----------------------------------------------------------------------------
-- 7. The trigger. A booking landing (insert booked, or a promotion/paid-drop-in
--    into booked) or leaving (booked -> cancelled/late_cancelled) fires it. A
--    no-show keeps the seat and does not. Demo members never email.
-- -----------------------------------------------------------------------------
create or replace function tg_instructor_booking_alert() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_gained int := 0; v_lost int := 0;
begin
  if new.is_demo or exists (select 1 from members m where m.id = new.member_id and m.is_demo) then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.status = 'booked' then v_gained := 1; end if;
  else
    if old.status <> 'booked' and new.status = 'booked' then v_gained := 1;
    elsif old.status = 'booked' and new.status in ('cancelled', 'late_cancelled') then v_lost := 1;
    end if;
  end if;
  if v_gained + v_lost > 0 then
    perform queue_instructor_booking_alert(new.occurrence_id, v_gained, v_lost);
  end if;
  return new;
end $$;
revoke execute on function tg_instructor_booking_alert() from public, anon, authenticated;

drop trigger if exists bookings_instructor_alert on bookings;
create trigger bookings_instructor_alert after insert or update of status on bookings
  for each row execute function tg_instructor_booking_alert();

-- -----------------------------------------------------------------------------
-- 8. Anon surface unchanged.
-- -----------------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
end $$;
