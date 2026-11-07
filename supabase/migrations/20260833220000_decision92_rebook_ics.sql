-- re-issues: notification_ics(uuid)
--
-- Decision 92 amendment (7 Nov 2026) — the booking_rebooked email carries a
-- calendar file that updates the member's existing event IN PLACE.
--
-- STEP 0 (read-only) findings:
--   * ics_member_vevent uses the member's OWN booking id as the VEVENT UID
--     (it finds the booking by occurrence_id + member_id and emits
--     ics_vevent(v_booking::text, ...)). The UID is therefore PER BOOKING.
--   * SEQUENCE = epoch(greatest(booking.updated_at, occurrence.updated_at)).
--   * deliver_notification attaches the .ics UNCONDITIONALLY at delivery:
--       v_ics := notification_ics(id);  send_via_resend(..., v_ics)
--     keyed on template_key. booking_rebooked was NOT in notification_ics's
--     list, so today the rebook email carries no calendar file.
--
-- Because rebook_member moves the booking IN PLACE (same booking row, now on
-- the new occurrence, updated_at = now()) and its payload already carries
-- occurrence_id = the new class, the single-file update-in-place case is
-- exactly what applies: SAME UID (per booking), HIGHER SEQUENCE (updated_at
-- moved), new DTSTART, METHOD:REQUEST — identical to how class_moved already
-- works. The record's "two files (CANCEL old + REQUEST new)" fallback is for
-- a UID that is NOT per booking, which is never reached here.
--
-- DELIBERATE DEVIATION from the task's "re-issue rebook_member": rebook_member
-- queues a notification; it does not post to Resend, and queue_notification has
-- no p_ics parameter — the .ics is built fresh at delivery by notification_ics
-- (the ONE .ics builder/attacher). So rebook_member structurally cannot attach
-- the file and needs no change: its payload already carries occurrence_id, the
-- booking already moved in place, and member_class_ics is untouched. The one
-- change is to notification_ics: add booking_rebooked to the member REQUEST
-- branch. Rebuilt from its newest definition (20260832200000).

create or replace function notification_ics(p_notification_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
        v_instr uuid; v_month text; v_events text; v_org text; v_att text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;

  if n.template_key in ('month_roster', 'month_roster_plain') then
    v_instr := nullif(n.payload ->> 'instructor_id', '')::uuid;
    v_month := nullif(n.payload ->> 'month_ym', '');
    if v_instr is null or v_month is null then return null; end if;
    v_events := instructor_month_vevents(n.studio_id, v_instr, to_date(v_month || '-01', 'YYYY-MM-DD'));
    if nullif(v_events, '') is null then return null; end if;
    return ics_calendar('PUBLISH', v_events);
  end if;

  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  select coalesce(nullif(s.contact_email, ''),
                  'notifications@' || notification_setting('from_domain'))
    into v_org from studios s where id = n.studio_id;

  -- booking_rebooked joins the member REQUEST branch: the booking moved in
  -- place, so ics_member_vevent emits the SAME UID (booking id) with a HIGHER
  -- SEQUENCE and the new class's DTSTART — the old event updates, it is not
  -- duplicated. It is not in the CANCEL set, so p_cancelled is false.
  if n.template_key in ('booking_confirmed', 'booking_rebooked', 'class_moved',
                        'class_cancelled', 'flex_booking_pending', 'flex_booking_not_confirmed') then
    select email into v_att from members where id = n.member_id;
    v_ve := ics_member_vevent(v_occ, n.member_id,
              (n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')), v_att, v_org);
    v_method := case when n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')
                     then 'CANCEL' else 'REQUEST' end;
  elsif n.template_key in ('instructor_assigned', 'booking_for_instructor') then
    select email into v_att from studio_staff
      where user_id = n.user_id and studio_id = n.studio_id limit 1;
    v_ve := ics_instructor_vevent(v_occ, false, v_att, v_org);
    v_method := 'REQUEST';
  else
    return null;
  end if;

  if v_ve is null then return null; end if;
  return ics_calendar(v_method, v_ve);
end $$;

-- service-only (reachable by neither client role), ACL re-asserted
revoke execute on function notification_ics(uuid) from public, anon, authenticated;
grant  execute on function notification_ics(uuid) to service_role;

-- Anon stays EXACTLY THIRTEEN.
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface is %, expected exactly thirteen', v_n;
  end if;
end $$;
