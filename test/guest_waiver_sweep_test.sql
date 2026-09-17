-- =============================================================================
-- sweep_guest_waivers robustness — UUID space 5eeb. Run after `supabase db reset`.
--
-- The real defect Decision 30 exposed: sweep_guest_waivers() ran the whole batch
-- in one transaction, so a single uncaught error on one pass took guest-waiver
-- reminders DOWN FOR EVERY TENANT. A free-first pass (host_member_id null) was
-- the first trigger — the host nudge queued to a null recipient and raised PT422.
--
-- Two independent halves of the fix, each with its own failing row here:
--   (a) skip the host nudge when host_member_id is null  -> STUDIO A
--   (b) isolate each pass in its own subtransaction       -> STUDIO C (a fault
--       injected by a temp trigger, so it fires regardless of the host guard)
-- Studio B is an ordinary guest pass — the SURVIVOR that must still be reminded
-- and whose host must still be nudged, whatever A and C do.
-- =============================================================================

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true', label; end if;
end $$;

-- --- fixtures ----------------------------------------------------------------
insert into studios (id,name,slug,timezone,currency,status) values
  ('5eeb5eeb-0000-0000-0000-00000000000a','Sweep A','5eeb-a','UTC','USD','active'),
  ('5eeb5eeb-0000-0000-0000-00000000000b','Sweep B','5eeb-b','UTC','USD','active'),
  ('5eeb5eeb-0000-0000-0000-00000000000c','Sweep C','5eeb-c','UTC','USD','active');
insert into studio_settings (studio_id) values
  ('5eeb5eeb-0000-0000-0000-00000000000a'),
  ('5eeb5eeb-0000-0000-0000-00000000000b'),
  ('5eeb5eeb-0000-0000-0000-00000000000c');
insert into locations (id,studio_id,name,is_primary) values
  ('5eeb5eeb-0000-0000-0000-00000000a001','5eeb5eeb-0000-0000-0000-00000000000a','Main',true),
  ('5eeb5eeb-0000-0000-0000-00000000b001','5eeb5eeb-0000-0000-0000-00000000000b','Main',true),
  ('5eeb5eeb-0000-0000-0000-00000000c001','5eeb5eeb-0000-0000-0000-00000000000c','Main',true);
insert into class_types (id,studio_id,name,duration_minutes,default_capacity) values
  ('5eeb5eeb-0000-0000-0000-00000000a002','5eeb5eeb-0000-0000-0000-00000000000a','Reformer',50,8),
  ('5eeb5eeb-0000-0000-0000-00000000b002','5eeb5eeb-0000-0000-0000-00000000000b','Reformer',50,8),
  ('5eeb5eeb-0000-0000-0000-00000000c002','5eeb5eeb-0000-0000-0000-00000000000c','Reformer',50,8);
insert into rooms (id,studio_id,location_id,name,capacity) values
  ('5eeb5eeb-0000-0000-0000-00000000a003','5eeb5eeb-0000-0000-0000-00000000000a','5eeb5eeb-0000-0000-0000-00000000a001','R1',8),
  ('5eeb5eeb-0000-0000-0000-00000000b003','5eeb5eeb-0000-0000-0000-00000000000b','5eeb5eeb-0000-0000-0000-00000000b001','R1',8),
  ('5eeb5eeb-0000-0000-0000-00000000c003','5eeb5eeb-0000-0000-0000-00000000000c','5eeb5eeb-0000-0000-0000-00000000c001','R1',8);
-- A class ~2h out for each studio: inside the sweep's (now, now+4h] window.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,name,starts_at,ends_at,capacity,booked_count,status) values
  ('5eeb5eeb-0000-0000-0000-00000000a004','5eeb5eeb-0000-0000-0000-00000000000a','5eeb5eeb-0000-0000-0000-00000000a001','5eeb5eeb-0000-0000-0000-00000000a002','5eeb5eeb-0000-0000-0000-00000000a003','Class A',now()+interval '2 hours',now()+interval '2 hours 50 min',8,1,'scheduled'),
  ('5eeb5eeb-0000-0000-0000-00000000b004','5eeb5eeb-0000-0000-0000-00000000000b','5eeb5eeb-0000-0000-0000-00000000b001','5eeb5eeb-0000-0000-0000-00000000b002','5eeb5eeb-0000-0000-0000-00000000b003','Class B',now()+interval '2 hours',now()+interval '2 hours 50 min',8,1,'scheduled'),
  ('5eeb5eeb-0000-0000-0000-00000000c004','5eeb5eeb-0000-0000-0000-00000000000c','5eeb5eeb-0000-0000-0000-00000000c001','5eeb5eeb-0000-0000-0000-00000000c002','5eeb5eeb-0000-0000-0000-00000000c003','Class C',now()+interval '2 hours',now()+interval '2 hours 50 min',8,1,'scheduled');
-- Members: A's is a free-first BOOKER (their own class); B and C each have a host
-- and a guest. All the guests are unsigned so the sweep chases them.
insert into members (id,studio_id,first_name,last_name,email,status,waiver_signed_at) values
  ('5eeb5eeb-0000-0000-0000-00000000a005','5eeb5eeb-0000-0000-0000-00000000000a','Ann','A','a-booker@example.com','lead',null),
  ('5eeb5eeb-0000-0000-0000-00000000b005','5eeb5eeb-0000-0000-0000-00000000000b','Bob','Host','b-host@example.com','active',now()),
  ('5eeb5eeb-0000-0000-0000-00000000b006','5eeb5eeb-0000-0000-0000-00000000000b','Bea','Guest','b-guest@example.com','lead',null),
  ('5eeb5eeb-0000-0000-0000-00000000c005','5eeb5eeb-0000-0000-0000-00000000000c','Cid','Host','c-host@example.com','active',now()),
  ('5eeb5eeb-0000-0000-0000-00000000c006','5eeb5eeb-0000-0000-0000-00000000000c','Cyd','Guest','c-guest@example.com','lead',null);
-- The passes. A: HOST-NULL (free first class). B and C: ordinary brought guests.
insert into guest_passes (studio_id,host_member_id,guest_member_id,guest_email,occurrence_id,status,waiver_signed_at) values
  ('5eeb5eeb-0000-0000-0000-00000000000a',null,'5eeb5eeb-0000-0000-0000-00000000a005','a-booker@example.com','5eeb5eeb-0000-0000-0000-00000000a004','invited',null),
  ('5eeb5eeb-0000-0000-0000-00000000000b','5eeb5eeb-0000-0000-0000-00000000b005','5eeb5eeb-0000-0000-0000-00000000b006','b-guest@example.com','5eeb5eeb-0000-0000-0000-00000000b004','invited',null),
  ('5eeb5eeb-0000-0000-0000-00000000000c','5eeb5eeb-0000-0000-0000-00000000c005','5eeb5eeb-0000-0000-0000-00000000c006','c-guest@example.com','5eeb5eeb-0000-0000-0000-00000000c004','invited',null);

-- Inject a fault on studio C ONLY: any notification insert for C raises. This is
-- a per-row failure that has NOTHING to do with the null host, so it isolates
-- half (b) — the per-pass subtransaction — from half (a).
create or replace function _sweep_boom() returns trigger language plpgsql as $$
begin
  if new.studio_id = '5eeb5eeb-0000-0000-0000-00000000000c' then
    raise exception 'injected fault for studio C';
  end if;
  return new;
end $$;
create trigger _sweep_boom_t before insert on notifications
  for each row execute function _sweep_boom();

-- --- run + assert ------------------------------------------------------------
do $$
declare v_res jsonb;
begin
  v_res := sweep_guest_waivers();   -- must NOT raise, even though C's row fails
  raise notice 'sweep returned %', v_res;
  perform set_config('t.res', v_res::text, false);
end $$;

-- Item 2: the skipped pass is recorded durably (a raise warning is ephemeral and
-- the return value is discarded by cron; a pass failing every 15 minutes would
-- otherwise be silent forever).
select expect_num('C: the skipped pass is recorded in audit_logs',
  (select count(*) from audit_logs
    where action = 'guest_waiver_sweep.pass_skipped'
      and studio_id = '5eeb5eeb-0000-0000-0000-00000000000c'), 1);

-- A second sweep with the fault still present must NOT write a second row —
-- one per pass per day, so a permanently bad row does not fill audit_logs.
do $$ begin perform sweep_guest_waivers(); end $$;
select expect_num('...and a second sweep does not duplicate it',
  (select count(*) from audit_logs
    where action = 'guest_waiver_sweep.pass_skipped'
      and studio_id = '5eeb5eeb-0000-0000-0000-00000000000c'), 1);

drop trigger _sweep_boom_t on notifications;
drop function _sweep_boom();

-- 1. The sweep completed and returned a summary (no exception propagated).
select expect_true('the sweep returned without raising',
  current_setting('t.res') is not null and (current_setting('t.res')::jsonb ? 'skipped'));

-- 2. Half (a): A's free-first BOOKER was reminded to sign.
select expect_num('A: the free-first booker got a waiver reminder',
  (select count(*) from notifications
    where member_id = '5eeb5eeb-0000-0000-0000-00000000a005' and template_key = 'guest_waiver_reminder'), 1);
-- 3. Half (a): NO host nudge for A — there is no host to nudge.
select expect_num('A: no host nudge (a free first class has no host)',
  (select count(*) from notifications
    where studio_id = '5eeb5eeb-0000-0000-0000-00000000000a' and template_key = 'guest_waiver_host_nudge'), 0);

-- 4. The SURVIVOR: B is reminded AND B's host is nudged, untouched by A or C.
select expect_num('B: the ordinary guest got a waiver reminder',
  (select count(*) from notifications
    where member_id = '5eeb5eeb-0000-0000-0000-00000000b006' and template_key = 'guest_waiver_reminder'), 1);
select expect_num('B: the host was nudged',
  (select count(*) from notifications
    where member_id = '5eeb5eeb-0000-0000-0000-00000000b005' and template_key = 'guest_waiver_host_nudge'), 1);

-- 5. Half (b): C's row failed and was SKIPPED and ROLLED BACK — no reminder for
--    it — yet the sweep still processed B. The reported skip count is >= 1.
select expect_num('C: the faulting row wrote nothing (rolled back)',
  (select count(*) from notifications
    where studio_id = '5eeb5eeb-0000-0000-0000-00000000000c'), 0);
select expect_true('C: the sweep counted it as skipped, not fatal',
  (current_setting('t.res')::jsonb->>'skipped')::int >= 1);

do $$ begin raise notice 'guest_waiver_sweep_test: all assertions passed'; end $$;
