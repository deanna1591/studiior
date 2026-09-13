-- Two advisor findings on hosted after 127, both the migration-056/020 shape.
--
-- 1. sign_waiver() let ANY authenticated member sign ANOTHER member's waiver,
--    for any member with a NULL user_id — which is every unclaimed guest, lead
--    and import, i.e. exactly the waiver-needing population, at any studio. The
--    guard read `m.user_id = auth.uid() or is_desk_up(...)`, and `null = uid` is
--    NULL, so `not (NULL or false)` is NULL and `if NULL then raise` is SKIPPED.
--    This is migration 020's lesson exactly — a boolean auth test that can be
--    NULL is a hole in a SECURITY DEFINER function. coalesce it to false. Signing
--    a waiver clears the §2.1 booking gate, so this was a real cross-tenant write.
--
-- 2. guest_pass_eligibility() is granted to `authenticated` with NO caller check
--    inside, and returns whether an email is a member/guest of a given studio —
--    tenant data, and an email-enumeration surface across tenants. Nothing on the
--    client calls it (book_guest calls it internally, and book_guest is SECURITY
--    DEFINER so the internal call survives the revoke). It LOSES THE GRANT rather
--    than gaining a guard — 086/103's stronger answer for a pure internal.

create or replace function sign_waiver(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  -- coalesce: user_id is null for every unclaimed member, and a NULL guard does
  -- not fire (migration 020).
  if not (coalesce(m.user_id = auth.uid(), false)
          or coalesce(is_desk_up(m.studio_id), false)) then
    raise exception 'that is not your waiver to sign' using errcode = 'PT403';
  end if;
  update members set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = p_member_id;
  update guest_passes set status = 'confirmed', waiver_signed_at = now()
   where guest_member_id = p_member_id and status = 'invited';
  return jsonb_build_object('ok', true, 'waiver_signed', true);
end $$;

revoke execute on function guest_pass_eligibility(uuid, uuid, text) from public, anon, authenticated;
