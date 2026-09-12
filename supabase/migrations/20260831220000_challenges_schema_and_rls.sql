-- Challenges, part 1: the leaderboard switch, the notification preference, and
-- two RLS holes that have been live since migration 001.
--
-- MEMBERS ONLY. Everything built for challenges is audience = 'member'. The
-- audience column and the instructor unique indexes stay, unused: if instructor
-- challenges ever arrive they are AUTO-ENROLLED and system-awarded, not joined,
-- which is a different mechanism and not what any of this builds.

-- -----------------------------------------------------------------------------
-- Leaderboard is per challenge and OFF by default (Decision 10: recognition,
-- not competition; a studio opts in). A member's own progress always shows; a
-- board is the only thing this gates.
-- -----------------------------------------------------------------------------
alter table challenges
  add column if not exists leaderboard_enabled boolean not null default false;

-- -----------------------------------------------------------------------------
-- A member can opt out of challenge mail like any other category. Default on,
-- the same as every other preference — a member who has never touched settings
-- has opted out of nothing.
-- -----------------------------------------------------------------------------
alter table notification_preferences
  add column if not exists challenge_email boolean not null default true;

-- notification_wanted maps a template key to its preference. create-or-replace
-- keeps the existing ACL (revoked from public/anon/authenticated; the definer
-- queue_notification calls it), so only the body changes here.
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite') then
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
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    -- All five challenge messages share one switch: a member wants challenge
    -- updates or does not, and five toggles for one feature is noise.
    when 'challenge_joined'      then p.challenge_email
    when 'challenge_milestone'   then p.challenge_email
    when 'challenge_completed'   then p.challenge_email
    when 'challenge_ending_soon' then p.challenge_email
    when 'challenge_opening'     then p.challenge_email
    else true
  end;
end $$;

-- -----------------------------------------------------------------------------
-- RLS: close two holes that have been open since 001.
--
-- `cp_member_self` was FOR ALL — a member could INSERT their own participant
-- row (past the join_deadline) and UPDATE their own `progress` to the goal and
-- mark themselves complete. That is members_self_update before migration 035,
-- in a new place: a member who can post their own completion makes the whole
-- feature decorative. Narrow it to SELECT. Joining and every progress write now
-- go through SECURITY DEFINER functions (owner, bypasses RLS), so the deadline
-- and "the system computes progress, never the member" become real boundaries.
-- -----------------------------------------------------------------------------
drop policy if exists cp_member_self on challenge_participants;
create policy cp_member_self on challenge_participants for select
  using (member_id in (select id from members where user_id = auth.uid()));

-- Desk enrolment also goes through join_challenge() now (it checks is_desk_up),
-- so the raw-insert policy goes with the member one — same deadline reasoning.
drop policy if exists cp_desk_enrol on challenge_participants;

-- "Is the viewer a participant of this challenge" — as a SECURITY DEFINER
-- helper, because a policy on challenge_participants that queries
-- challenge_participants recurses (the subquery re-applies the policy, forever).
-- The original cp_leaderboard did exactly that and never fired only because no
-- reader had ever been a member session; the fix is to answer the question
-- through a function that bypasses RLS rather than inside the policy.
create function auth_participates_in(p_challenge_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from challenge_participants cp
    join members m on m.id = cp.member_id
    where cp.challenge_id = p_challenge_id and m.user_id = auth.uid());
$$;
revoke execute on function auth_participates_in(uuid) from public, anon;
grant  execute on function auth_participates_in(uuid) to authenticated, service_role;

-- Leaderboard visibility now REQUIRES the challenge's board to be on. With it
-- off a participant sees co-participants nowhere — but their OWN row still comes
-- through cp_member_self above, which is not gated on the board. A member who
-- could not see their own progress would be a worse bug than the leak this
-- closes, so the two policies are deliberately separate: own row always, others
-- only when the studio opted in.
drop policy if exists cp_leaderboard on challenge_participants;
create policy cp_leaderboard on challenge_participants for select
  using (
    exists (
      select 1 from challenges c
       where c.id = challenge_participants.challenge_id
         and c.leaderboard_enabled
    )
    and auth_participates_in(challenge_participants.challenge_id)
  );
