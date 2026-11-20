-- creates: render_email(uuid, text, text, text, text, text, jsonb, text, text)
-- re-issues: finalise_pay_true_up(uuid), activate_purchase(uuid, uuid, uuid, integer, character, text, text, boolean), xendit_begin_purchase(uuid, uuid), render_notification(uuid), pay_statement(uuid, uuid)
-- =============================================================================
-- Housekeeping, 20 Nov 2026.
--
-- Decision 75(j) "pay follows the seat, not the body": finalise_pay_true_up pays
-- the greater of the seats booked at the cut-off and the seats consumed
-- (attended, no-show, late cancelled). The basis records heads_consumed,
-- heads_basis ('cutoff' or 'consumed') and heads_paid beside checked_in and
-- finalise_of. pay_statement carries heads_paid so the line reads
-- "N booked · M checked in · paid on H". Pay lines finalised before this are
-- not recalculated (settled by hand).
--
-- Decision 62 note: the intro offer refusal in activate_purchase and
-- xendit_begin_purchase loses its em dash; lib/plan-kind.mjs carries the same
-- words.
--
-- Decision 80 note: render_email takes the recipient's role and shows the
-- billing footer line only to the owner; render_notification passes the role
-- from the recipient's studio_staff row. The always-send footer sentence is
-- rewritten plain. Adding a parameter is an overload, so the 8-argument
-- render_email is dropped first (its callers resolve to the new default).
--
-- Every body is pg_get_functiondef of the live definition, which matches the
-- newest migration file (hosted drift IN STEP), with asserted replacements.
-- No new anon RPC: anon stays EXACTLY FOURTEEN.
-- =============================================================================

drop function render_email(uuid, text, text, text, text, text, jsonb, text);

CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text, p_recipient_role text DEFAULT NULL::text)
 RETURNS TABLE(subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype;
  v_is_staff boolean; v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text; v_class_when text;
  v_tok text; v_stripped text[] := '{}';
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;


  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
  end loop;

  -- Decision 80a fix: the class card's ONE detail line, built from the occurrence
  -- so every class email reads the same — Day · time · room · with {instructor},
  -- times via fmt_clock in the studio format, missing parts dropped cleanly.
  v_occ_id := nullif(p_payload ->> 'occurrence_id', '')::uuid;
  if v_occ_id is not null then
    select concat_ws(' · ',
             nullif(to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'), ''),
             fmt_clock(o.starts_at, s.timezone, v_fmt),
             nullif(rm.name, ''),
             nullif('with ' || split_part(coalesce(i.display_name, ''), ' ', 1), 'with '))
      into v_class_line
      from class_occurrences o
      left join rooms rm on rm.id = o.room_id
      left join instructors i on i.id = o.instructor_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_line}', coalesce(v_class_line, ''));
  v_txt  := replace(v_txt,  '{class_line}', coalesce(v_class_line, ''));
  v_html := replace(v_html, '{class_line}', coalesce(v_class_line, ''));

  -- Decision 101: {class_when} — the instructor-facing class line, "Class on Day
  -- at time" plus the room ONLY when the studio has more than one. Resolved from
  -- occurrence_id, so every instructor template that carries it reads the same,
  -- and the room rule lives in one place. Known-optional (strip-exempt below).
  if v_occ_id is not null then
    select coalesce(o.name, ct.name, 'your class') || ' on '
           || to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth')
           || ' at ' || fmt_clock(o.starts_at, s.timezone, v_fmt)
           || case when (select count(*) from rooms where studio_id = s.id and status = 'active') > 1
                     and nullif(rm.name, '') is not null then ' in ' || rm.name else '' end
      into v_class_when
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      left join rooms rm on rm.id = o.room_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_when}', coalesce(v_class_when, ''));
  v_txt  := replace(v_txt,  '{class_when}', coalesce(v_class_when, ''));
  v_html := replace(v_html, '{class_when}', coalesce(v_class_when, ''));

  -- Decision 101: {schedule_link} — the instructor's own schedule. Filled for a
  -- staff recipient when the payload did not already supply it (the digest and a
  -- test send supply their own). Known-optional (strip-exempt below).
  if v_is_staff then
    v_sub  := replace(v_sub,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_txt  := replace(v_txt,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_html := replace(v_html, '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
  end if;

  -- Accent (80a): a static template button carries {accent}/{accent_on}.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- STRIP any residual {token}: a known-optional one silently, anything else to
  -- empty AND recorded in `stripped` (deliver_notification logs it). No token
  -- ever reaches a member.
  for v_tok in
    select distinct (regexp_matches(coalesce(v_sub,'') || E'\n' || coalesce(v_txt,'') || E'\n' || coalesce(v_html,''),
                                    '\{([a-z_][a-z0-9_]*)\}', 'g'))[1]
  loop
    if not (v_tok = any (array['where_line','free_first_line','free_first_html',
                               'next_three_line','next_three_html','system_text','system_html','class_line',
                               'class_when','schedule_link','replaces_line','replaces_html'])) then
      v_stripped := array_append(v_stripped, v_tok);
    end if;
    v_sub  := replace(v_sub,  '{' || v_tok || '}', '');
    v_txt  := replace(v_txt,  '{' || v_tok || '}', '');
    v_html := replace(v_html, '{' || v_tok || '}', '');
  end loop;

  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''), nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/settings';
  end if;

  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  v_always := p_template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite', 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then 'Your billing: ' || v_link end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>' end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  -- The FLUID frame. The content table ("sd-card") is width 100% / max-width 600px
  -- so it reflows on a phone; the <style> media query shrinks the padding and body
  -- text under 480px and caps images; the MSO ghost table stays 600 for Outlook.
  return query select v_sub, v_txt || E'\n\n--\n' || v_foot_txt,
    '<style>'
      || '.sd-body img{max-width:100%;height:auto}'
      || '@media only screen and (max-width:480px){'
      || '.sd-card{width:100%!important;border-radius:0!important}'
      || '.sd-pad{padding-left:16px!important;padding-right:16px!important}'
      || '.sd-body{font-size:14px!important;line-height:22px!important}'
      || '}'
      || '</style>'
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="100%" class="sd-card" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:100%;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td class="sd-pad" style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td class="sd-pad sd-body" style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td class="sd-pad" style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$;

CREATE OR REPLACE FUNCTION public.finalise_pay_true_up(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; v_rec instructor_pay_records%rowtype;
  s studio_settings%rowtype; v_kind session_kind; c jsonb;
  v_heads int; v_checked int; v_consumed int; v_cut int; v_basis text; v_new int; v_delta int; p pay_periods%rowtype; v_id uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not is_service_context() and not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'the finalisation true-up is a background job' using errcode = 'PT403';
  end if;

  -- Only when the studio pays on attendance. OFF => the booked basis stands.
  select * into s from studio_settings where studio_id = o.studio_id;
  if not coalesce(s.finalise_attendance, false) then
    return jsonb_build_object('ok', true, 'skipped', 'finalisation_off');
  end if;

  -- Only a committed, still-scheduled class trues up on heads. A not_running or
  -- otherwise cancelled class is paid by its cancellation rule, not a count.
  if o.committed_at is null or o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'skipped', 'not a committed running class');
  end if;

  -- A private/duo/trio is a flat line, untouched by headcount.
  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  if coalesce(v_kind, 'group') <> 'group' then
    return jsonb_build_object('ok', true, 'skipped', 'flat_rate');
  end if;

  select * into v_rec from instructor_pay_records
   where occurrence_id = p_occurrence_id and type = 'class';
  if not found then
    return jsonb_build_object('ok', true, 'record', 'none');
  end if;

  -- Idempotent: the in-place path stamps basis.finalised_at; the closed path
  -- leaves an adjustment keyed on finalise_of. Either means we are done.
  if (v_rec.basis ? 'finalised_at')
     or exists (select 1 from instructor_pay_records
                 where type = 'adjustment' and basis ->> 'finalise_of' = p_occurrence_id::text) then
    return jsonb_build_object('ok', true, 'already', 'finalised');
  end if;

  -- Decision 75(j): pay follows the seat, not the body. Seats consumed are
  -- attended, no-show and late cancelled (a late cancel is after the cut-off by
  -- definition); a still-booked seat at finalisation is one the sweep is about
  -- to mark attended or no-show, so it counts too. An on-time cancel never
  -- counts. The heads paid are the greater of the count at the cut-off and the
  -- seats consumed, so pay never drops below the cut-off promise (Decision 32).
  -- checked_in is still recorded so the statement can say "M checked in".
  select count(distinct member_id)::int into v_checked
    from check_ins where occurrence_id = p_occurrence_id;
  select count(*)::int into v_consumed
    from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'attended', 'no_show', 'late_cancelled');
  v_cut := coalesce(o.booked_at_cutoff, 0);
  v_heads := greatest(v_cut, v_consumed);
  v_basis := case when v_consumed > v_cut then 'consumed' else 'cutoff' end;

  c := compute_class_pay_run(p_occurrence_id, v_heads);
  if not (c ->> 'ok')::boolean then
    return jsonb_build_object('ok', true, 'recompute', c);
  end if;
  v_new := (c ->> 'amount_cents')::int;
  v_delta := v_new - v_rec.amount_cents;

  select * into p from pay_periods where id = v_rec.period_id;

  if p.status = 'open' then
    -- Raise OR lower in place, re-copy the instructor from the occurrence (an
    -- accepted cover is paid for the class they taught), and record what the
    -- line now rests on so the statement can say "M checked in · paid on H".
    update instructor_pay_records
       set amount_cents  = v_new,
           instructor_id = o.instructor_id,
           basis = (c -> 'basis')
                   || jsonb_build_object('finalise_of', p_occurrence_id,
                                         'checked_in', v_checked,
                                         'heads_consumed', v_consumed,
                                         'heads_basis', v_basis,
                                         'heads_paid', v_heads,
                                         'finalised_at', now())
     where id = v_rec.id;
    return jsonb_build_object('ok', true, 'trued_up', 'in_place',
      'checked_in', v_checked, 'heads_consumed', v_consumed, 'heads_basis', v_basis,
      'heads_paid', v_heads, 'delta_cents', v_delta, 'amount_cents', v_new);
  end if;

  -- The period is CLOSED — immutable, already paid. The difference goes in the
  -- next open period as an adjustment (signed; it may claw back), naming the
  -- class and the period it came from so the statement can label it "from the
  -- previous period". delta 0 needs no adjustment.
  if v_delta = 0 then
    return jsonb_build_object('ok', true, 'closed', true, 'checked_in', v_checked, 'heads_consumed', v_consumed,
      'heads_basis', v_basis, 'heads_paid', v_heads, 'delta_cents', 0);
  end if;
  p := next_open_pay_period(o.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, amount_cents, currency,
    rate_version_id, basis, note, created_by)
  values (o.studio_id, o.instructor_id, p.id, 'adjustment', v_delta, (c ->> 'currency'),
          (c ->> 'rate_version_id')::uuid,
          jsonb_build_object('finalise_of', p_occurrence_id, 'original_period', v_rec.period_id,
            'checked_in', v_checked, 'heads_consumed', v_consumed, 'heads_basis', v_basis,
            'heads_paid', v_heads, 'booked_at_cutoff', v_cut,
            'reason', 'attendance correction'),
          o.name || ': attendance correction (from the previous period)', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'trued_up', 'adjustment',
    'adjustment_id', v_id, 'checked_in', v_checked, 'heads_consumed', v_consumed,
    'heads_basis', v_basis, 'heads_paid', v_heads, 'delta_cents', v_delta);
end $function$;

CREATE OR REPLACE FUNCTION public.activate_purchase(p_studio_id uuid, p_member_id uuid, p_plan_id uuid, p_price_cents integer, p_currency character, p_stripe_customer text DEFAULT NULL::text, p_stripe_subscription text DEFAULT NULL::text, p_enforce_seat_cap boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  plan membership_plans%rowtype; v_ms uuid; v_bal int;
  v_today date; v_start timestamptz; v_end timestamptz;
  v_taken int;
  -- Decision 12 amendment: pack-shaped plans and their finite bundle size.
  v_is_pack boolean; v_credits int; v_validity int;
  v_group uuid;  -- Decision 76: a group purchase (no membership)
begin
  -- Locked. See above.
  select * into plan from membership_plans
   where id = p_plan_id and studio_id = p_studio_id
   for update;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  -- Decision 76: a GROUP plan has NO membership and NO credits. Create the
  -- group purchase and return its id — the caller tags the payment with
  -- group_purchase_id (not membership_id). Placed before the seat-cap and
  -- membership path (a group is not a held membership, so neither applies).
  if plan.type = 'group' then
    insert into group_purchases (studio_id, host_member_id, plan_id, group_size, expires_on, status)
    values (p_studio_id, p_member_id, plan.id, plan.group_size,
            studio_today(p_studio_id) + coalesce(plan.group_book_within_days, 30), 'unbooked')
    returning id into v_group;
    return v_group;
  end if;

  -- Decision 62: an intro offer is bought once per person. If the plan being
  -- activated is a trial and this member has EVER held a membership on any trial
  -- plan of this studio (any status), refuse before anything is written. Keyed
  -- on plan.type = 'trial', so a Decision 61 complimentary grant on a non-trial
  -- plan is never caught.
  if plan.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.member_id = p_member_id
       and ms.studio_id = p_studio_id
       and mp.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers and you have had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  -- Decision 24: the seat cap, under the lock, before anything is written.
  if coalesce(p_enforce_seat_cap, true)
     and plan.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
  then
    v_taken := plan_seats_taken(plan.id);
    if v_taken >= plan.max_active_members then
      raise exception '% is full: % of % places are taken.',
                      plan.name, v_taken, plan.max_active_members
        using errcode = 'PT409',
              hint = 'Somebody has to leave this plan, or its limit has to go up, '
                     'before another place can be sold.';
    end if;
  end if;

  v_today := studio_today(p_studio_id);
  v_start := now();
  -- Null for a pack, a drop-in and a trial, which is what makes the columns
  -- mean something: a period present is a thing that renews.
  v_end   := plan_period_end(plan.id, v_start);

  -- Decision 12 amendment: resolve the pack bundle. A drop-in is exactly one
  -- class; a trial is plan.credits (default 1); a class pack is plan.credits.
  -- Recurring plans are not packs (their allowance is credits_per_period).
  v_is_pack := plan.type in ('class_pack', 'drop_in', 'trial');
  v_credits := case plan.type
                 when 'class_pack' then plan.credits
                 when 'drop_in'    then 1
                 when 'trial'      then coalesce(plan.credits, 1)
                 else null end;
  -- class_pack keeps its existing validity (NULL = no expiry); drop_in / trial
  -- default to 30 days so a paid class cannot sit unusable or forever.
  v_validity := case plan.type
                  when 'class_pack' then plan.validity_days
                  when 'drop_in'    then coalesce(plan.validity_days, 30)
                  when 'trial'      then coalesce(plan.validity_days, 30)
                  else null end;

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    current_period_start, current_period_end, renews_on, credits_reset_at,
    credits_remaining, expires_on, auto_renew,
    stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, p_member_id, plan.id,
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    -- §7.1: the price agreed at purchase, snapshotted. Never re-read from the
    -- plan afterwards, so editing a plan cannot reprice anybody already on it.
    coalesce(p_price_cents, plan.price_cents),
    coalesce(nullif(p_currency, ''), plan.currency),
    v_today,
    v_start, v_end,
    -- renews_on is the period end as one of the STUDIO's dates.
    (v_end at time zone (select s.timezone from studios s where s.id = p_studio_id))::date,
    -- Decision 3: no rollover. The allowance resets at the period boundary
    -- rather than accumulating, and only where there is an allowance at all —
    -- Decision 12 makes a null credits_per_period mean unlimited.
    case when plan.type = 'recurring' and plan.credits_per_period is not null
         then v_end end,
    -- credits_remaining: a recurring plan's per-period allowance (null =
    -- unlimited, Decision 12); a pack-shaped plan its finite bundle.
    case when plan.type = 'recurring' then plan.credits_per_period
         else v_credits end,
    -- expires_on: pack-shaped plans only (a recurring plan renews, it does not
    -- expire). class_pack with no validity -> NULL (no expiry, unchanged).
    case when v_is_pack and v_validity is not null then v_today + v_validity end,
    plan.type = 'recurring',
    p_stripe_customer, nullif(p_stripe_subscription, '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows. credits_remaining above is a
  -- cache of this, written in the same transaction and never independently.
  -- Decision 12 amendment: drop_in and trial grant through the ledger too.
  if v_is_pack and coalesce(v_credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = p_member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at, actor_user_id)
    values (p_studio_id, p_member_id, v_ms, v_credits, 'purchase',
            v_bal + v_credits,
            case when v_validity is not null
                 then (v_today + v_validity + 1)::timestamptz end,
            auth.uid());
  end if;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
  values (p_studio_id, v_ms, 'created',
          (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
          auth.uid());

  return v_ms;
end $function$;

CREATE OR REPLACE FUNCTION public.xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
 RETURNS TABLE(purchase_id uuid, amount_cents integer, currency character, credit_applied_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
        v_avail int; v_applied int; v_due int;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into mp from membership_plans
   where id = p_plan_id and studio_id = p_studio_id and visibility = 'public' and status = 'active';
  if mp.id is null then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  if mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  if p_plan_id = (select intro_offer_plan_id from studio_settings where studio_id = p_studio_id)
     and coalesce((select intro_offer_exclusive from studio_settings where studio_id = p_studio_id), false)
     and not coalesce((intro_window(v_member) ->> 'active')::boolean, false) then
    raise exception 'That plan is only available during your intro offer.' using errcode = 'PT409';
  end if;

  if mp.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp2 on mp2.id = ms.plan_id
     where ms.member_id = v_member and ms.studio_id = p_studio_id and mp2.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers and you have had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  if mp.type = 'recurring' then
    select ms.id into v_renew
      from memberships ms
     where ms.studio_id = p_studio_id and ms.member_id = v_member
       and ms.plan_id = p_plan_id and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;
  end if;

  if v_renew is null
     and mp.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
     and plan_seats_taken(mp.id) >= mp.max_active_members
  then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  v_avail := reservation_credit_available(p_studio_id, v_member);

  -- Decision 103(f): credit covers the whole total. No Xendit, no floor; complete
  -- now and return due 0 so the app lands straight on the success screen.
  if v_avail >= mp.price_cents then
    insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                  renews_membership_id, credit_applied_cents)
    values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency, v_renew, mp.price_cents)
    returning id into v_id;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, mp.currency, mp.price_cents;
    return;
  end if;

  -- Partial (or no) credit: cap so the online payment is >= the processor minimum.
  v_applied := least(greatest(v_avail, 0), greatest(mp.price_cents - 2000, 0));
  v_due := mp.price_cents - v_applied;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                renews_membership_id, credit_applied_cents)
  values (p_studio_id, v_member, p_plan_id, v_due, mp.currency, v_renew, v_applied)
  returning id into v_id;

  return query select v_id, v_due, mp.currency, v_applied;
end $function$;

CREATE OR REPLACE FUNCTION public.render_notification(p_notification_id uuid)
 RETURNS TABLE(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_staff_role text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; v_first text;
  v_ov_key text; v_ov_subject text; v_ov_body text; v_ov_html text;
  v_rsub text; v_rtxt text; v_rhtml text; v_rstrip text[];
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select o.key, o.subject, o.body, o.body_html
    into v_ov_key, v_ov_subject, v_ov_body, v_ov_html
    from notification_templates_overrides o
   where o.studio_id = n.studio_id and o.key = n.template_key;
  select * into m from members where id = n.member_id;

  v_is_staff := n.recipient_type = 'staff';
  if v_is_staff then
    select coalesce(ss.email, pr.email), coalesce(pr.full_name, ss.email), ss.role::text
      into v_staff_email, v_staff_name, v_staff_role
      from studio_staff ss
      left join profiles pr on pr.id = ss.user_id
     where ss.user_id = n.user_id and ss.studio_id = n.studio_id
     limit 1;
  end if;
  select * into s from studios where id = n.studio_id;
  if t.key is null then
    raise exception 'no template %', n.template_key using errcode = 'PT404';
  end if;

  if v_ov_key is not null then
    v_sub := v_ov_subject; v_txt := v_ov_body; v_html := v_ov_html;
  else
    v_sub := t.subject; v_txt := t.text_body; v_html := t.html_body;
  end if;

  v_first := coalesce(m.first_name, split_part(coalesce(v_staff_name, ''), ' ', 1), 'there');

  select re.subject, re.text_body, re.html_body, re.stripped
    into v_rsub, v_rtxt, v_rhtml, v_rstrip
    from render_email(n.studio_id, n.template_key, n.recipient_type, v_sub, v_txt, v_html, n.payload, v_first, v_staff_role) re;

  return query select
    coalesce(nullif(n.payload ->> 'to_email', ''), v_staff_email, m.email),
    s.name, s.contact_email, v_rsub, v_rtxt, v_rhtml, v_rstrip;
end $function$;

CREATE OR REPLACE FUNCTION public.pay_statement(p_instructor_id uuid, p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean; v_conf bigint; v_held bigint;
  v_settle_dow int; v_settle_offset int; v_held_count int;
  v_paid_on date; v_method text; v_reference text; v_status text;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  v_studio := p.studio_id;

  select exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                  where i.id = p_instructor_id and ss.user_id = auth.uid())
    into v_self;
  if not coalesce(is_manager_up(v_studio), false) and not coalesce(v_self, false) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = v_studio;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = v_studio;
  select display_name into v_name from instructors where id = p_instructor_id;

  -- Paid = a settlement row for this instructor and period (the money moved
  -- elsewhere and the studio recorded it). That is the third header state.
  select paid_on, method, reference into v_paid_on, v_method, v_reference
    from instructor_pay_settlements
   where period_id = p_period_id and instructor_id = p_instructor_id;
  v_status := case when v_paid_on is not null then 'paid' else p.status::text end;

  select jsonb_agg(l order by l ->> 'sort'), coalesce(sum(amt), 0)
    into v_lines, v_total
  from (
    select
      jsonb_build_object(
        'sort', coalesce(to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
                         to_char(r.created_at at time zone v_tz, 'YYYY-MM-DD HH24:MI')),
        'type', r.type,
        'date', coalesce(to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon'),
                         to_char(r.created_at at time zone v_tz, 'FMDay FMDD FMMon')),
        'time', fmt_clock_s(o.starts_at, v_studio),
        'name', case r.type
                  when 'class' then o.name
                  when 'conversion' then 'Conversion — ' || coalesce(r.basis ->> 'member_name', 'a member')
                                          || ' (' || coalesce(r.basis ->> 'plan_name', 'a plan') || ')'
                  else coalesce(r.note, 'Adjustment') end,
        'status', case
                    when r.type <> 'class' then null
                    when o.status <> 'cancelled' then 'ran'
                    when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                    else 'cancelled — ' || o.cancellation_cause::text end,
        -- Decision 75(i): booked at cutoff, and the checked-in count once the
        -- class has been finalised (null before — "awaiting attendance").
        'booked', case when r.type = 'class' then o.booked_at_cutoff end,
        'checked_in', case when r.type = 'class' then (r.basis ->> 'checked_in')::int end,
        'heads_paid', case when r.type = 'class' then coalesce((r.basis ->> 'heads_paid')::int, (r.basis ->> 'checked_in')::int) end,
        'finalised', case when r.type = 'class' then (r.basis ? 'finalised_at') else null end,
        'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
        -- DECISION 32 note, now a detail line: a late booker after the cutoff.
        'headcount_note', case
            when (r.basis ->> 'booked_at_start') is not null
             and (r.basis ->> 'booked_at_start')::int
                 > coalesce((r.basis ->> 'booked_at_cutoff')::int, 0)
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || (r.basis ->> 'booked_at_start') || ' at start'
            when r.type = 'adjustment' and (r.basis ->> 'true_up_of') is not null
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || coalesce(r.basis ->> 'booked_at_start', '0') || ' at start'
            else null end,
        -- A class or adjustment carried from a now-closed period (straggler /
        -- finalise true-up) is tagged "from the previous period".
        'from_previous_period', ((r.basis ->> 'original_period') is not null
                                 and (r.basis ->> 'original_period') <> p_period_id::text),
        -- A conversion bonus can land in a period after the class that earned
        -- it; show that first-class date so the line reads sensibly.
        'first_class_on', case when r.type = 'conversion' then r.basis ->> 'first_class_on' end,
        'capacity',  case when r.type = 'class' then o.capacity end,
        'amount_cents', r.amount_cents,
        'confirmed', r.confirmed_at is not null,
        'payable', r.type <> 'class' or r.confirmed_at is not null,
        'note', r.note,
        'basis', r.basis) as l,
      r.amount_cents as amt
      from instructor_pay_records r
      left join class_occurrences o on o.id = r.occurrence_id
     where r.instructor_id = p_instructor_id and r.period_id = p_period_id
  ) x;

  select coalesce(sum(amount_cents) filter (where type <> 'class' or confirmed_at is not null), 0),
         coalesce(sum(amount_cents) filter (where type = 'class' and confirmed_at is null), 0),
         count(*) filter (where type = 'class' and confirmed_at is null)
    into v_conf, v_held, v_held_count
    from instructor_pay_records where instructor_id = p_instructor_id and period_id = p_period_id;

  select jsonb_object_agg(t, s) into v_sub from (
    select type::text as t, sum(amount_cents) as s
      from instructor_pay_records
     where instructor_id = p_instructor_id and period_id = p_period_id
     group by type) y;

  return jsonb_build_object('ok', true,
    'instructor_id', p_instructor_id, 'instructor_name', v_name,
    'period_id', p.id, 'starts_on', p.starts_on, 'ends_on', p.ends_on,
    'status', v_status, 'currency', v_cur,
    'settle_on', pay_settle_on(p.ends_on, v_settle_dow, v_settle_offset),
    'paid_on', v_paid_on, 'paid_method', v_method, 'paid_reference', v_reference,
    'lines', coalesce(v_lines, '[]'::jsonb),
    'subtotals', coalesce(v_sub, '{}'::jsonb),
    'total_cents', v_total,
    'confirmed_cents', v_conf, 'held_cents', v_held, 'held_count', v_held_count);
end $function$;

revoke execute on function render_email(uuid, text, text, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant  execute on function render_email(uuid, text, text, text, text, text, jsonb, text, text) to service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 14 then raise exception 'anon surface is % not 14', n; end if;
  if has_function_privilege('authenticated', 'render_email(uuid, text, text, text, text, text, jsonb, text, text)', 'execute') then
    raise exception 'render_email reopened to authenticated';
  end if;
end $$;
