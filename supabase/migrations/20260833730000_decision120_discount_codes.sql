-- creates: discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz), discount_code_price_run(uuid, text, uuid, text, timestamptz), discount_code_hold_run(uuid, uuid, uuid, uuid, text, uuid, uuid, int, int), discount_code_return_run(uuid), tg_payment_discount_code_fill(), tg_payment_discount_code_status(), tg_purchase_discount_code_release(), discount_code_preview(uuid, text, uuid, uuid, uuid), discount_code_prefix(uuid), discount_code_random(int), discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean), discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean), discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean), discount_code_cancel(uuid), discount_code_batches_list(uuid), discount_code_rows(uuid)
-- re-issues: xendit_begin_purchase(uuid, uuid, text), plan_buy_begin(uuid, uuid, text, text, text, text, boolean), record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text), record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text), sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean, text), xendit_activate_success_internal(uuid, text, text), plan_purchase_activate_run(uuid, uuid), private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text), private_book(uuid, uuid, timestamptz, jsonb, text, text), sales_totals(uuid, date, date, uuid, text)
--
-- Decision 120: discount codes.
--
-- THE SHAPE. A batch (discount_code_batches) is either 'batch', many
-- single-use codes, or 'shared', one owner-chosen code with a maximum number
-- of uses and once per person. Every code is a discount_codes row (a shared
-- code is one row). Every attempt to use a code is a discount_code_uses row:
--   held      a pending checkout carries it (only while that checkout is
--             pending; released when it expires or fails)
--   redeemed  the payment succeeded (set by the payments trigger, the one
--             redemption path for Xendit, desk and instructor sales)
--   released  the checkout expired or failed
--   returned  the payment was refunded in full while the code was still valid
-- A payment carries discount_code_use_id and a snapshot of the code text
-- (discount_code) for receipts and the BIR invoice.
--
-- PRICE. The code price is the list price less the code's percent
-- (promo_sale_cents, the Decision 117 rounding). No stacking: the buyer pays
-- the lower of the running promotion's price and the code price, and only
-- that one is recorded (a promotion_id or a discount_code_use_id, never both).
--
-- REFUNDS. One helper, discount_code_return_run, called by a trigger on
-- payments when a payment becomes fully refunded, so every refund path
-- (refund_payment_run, record_refund, apply_payment_refund, and any later one)
-- returns the code. A partial refund keeps the code used.
--
-- GUESSING. Codes are 8 random characters from a 31-character alphabet with no
-- look-alikes. Every check is logged in discount_code_checks and limited per
-- studio, per buyer email and per member over ten minutes.
--
-- NO NEW ANON FUNCTION. plan_buy_begin gains p_code and p_preview (a preview
-- writes no purchase); the anon surface stays exactly fifteen.

-- ---- Tables ---------------------------------------------------------------------
create table if not exists discount_code_batches (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios(id) on delete cascade,
  kind             text not null check (kind in ('batch', 'shared')),
  name             text not null check (length(btrim(name)) between 1 and 60),
  pct              int  not null check (pct between 1 and 90),
  starts_on        date not null,
  ends_on          date not null,
  plan_ids         uuid[] not null default '{}',
  private_sessions boolean not null default false,
  max_uses         int check (max_uses is null or max_uses > 0),
  cancelled_at     timestamptz,
  created_by       uuid references profiles(id),
  created_at       timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (kind = 'batch' or max_uses is not null)
);
create index if not exists discount_code_batches_studio on discount_code_batches (studio_id, created_at desc);

create table if not exists discount_codes (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid not null references studios(id) on delete cascade,
  batch_id     uuid not null references discount_code_batches(id) on delete cascade,
  code         text not null check (code ~ '^[A-Z0-9-]{3,40}$'),
  cancelled_at timestamptz,
  cancelled_by uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create unique index if not exists discount_codes_studio_code on discount_codes (studio_id, upper(code));
create index if not exists discount_codes_batch on discount_codes (batch_id);

create table if not exists discount_code_uses (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  code_id               uuid not null references discount_codes(id) on delete cascade,
  batch_id              uuid not null references discount_code_batches(id) on delete cascade,
  member_id             uuid references members(id) on delete set null,
  buyer_email           text,
  plan_id               uuid references membership_plans(id) on delete set null,
  private_occurrence_id uuid references class_occurrences(id) on delete set null,
  purchase_id           uuid references xendit_purchases(id) on delete set null,
  payment_id            uuid references payments(id) on delete set null,
  status                text not null check (status in ('held', 'redeemed', 'released', 'returned')),
  list_cents            int,
  amount_off_cents      int not null default 0,
  created_at            timestamptz not null default now(),
  redeemed_at           timestamptz,
  released_at           timestamptz,
  returned_at           timestamptz
);
create index if not exists discount_code_uses_code on discount_code_uses (code_id, status);
create index if not exists discount_code_uses_batch on discount_code_uses (batch_id, status);

create table if not exists discount_code_checks (
  id          bigserial primary key,
  studio_id   uuid not null references studios(id) on delete cascade,
  member_id   uuid,
  buyer_email text,
  ok          boolean not null,
  created_at  timestamptz not null default now()
);
create index if not exists discount_code_checks_recent on discount_code_checks (studio_id, created_at desc);

alter table xendit_purchases add column if not exists discount_code_use_id uuid references discount_code_uses(id) on delete set null;
alter table payments add column if not exists discount_code_use_id uuid references discount_code_uses(id) on delete set null;
alter table payments add column if not exists discount_code text;

alter table discount_code_batches enable row level security;
alter table discount_codes enable row level security;
alter table discount_code_uses enable row level security;
alter table discount_code_checks enable row level security;
drop policy if exists discount_code_batches_read on discount_code_batches;
create policy discount_code_batches_read on discount_code_batches for select to authenticated
  using (coalesce(is_manager_up(studio_id), false));
drop policy if exists discount_codes_read on discount_codes;
create policy discount_codes_read on discount_codes for select to authenticated
  using (coalesce(is_manager_up(studio_id), false));
drop policy if exists discount_code_uses_read on discount_code_uses;
create policy discount_code_uses_read on discount_code_uses for select to authenticated
  using (coalesce(is_manager_up(studio_id), false));
revoke all on discount_code_batches, discount_codes, discount_code_uses, discount_code_checks
  from public, anon, authenticated;
grant select on discount_code_batches, discount_codes, discount_code_uses to authenticated;
grant all on discount_code_batches, discount_codes, discount_code_uses, discount_code_checks to service_role;
grant usage on sequence discount_code_checks_id_seq to service_role;

-- ---- discount_code_check_run ----------------------------------------------------
-- The one decision: may this person use this code on this plan (or a private
-- session) now, and at what price. Logs the check and rate-limits. Never
-- writes a use; the caller holds it.
create or replace function discount_code_check_run(
  p_studio_id uuid, p_code text, p_plan_id uuid, p_private boolean,
  p_member_id uuid, p_email text, p_list_cents int, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text; v_email text; c discount_codes%rowtype; b discount_code_batches%rowtype;
        v_tz text; v_today date; v_used int; v_held int; v_price int;
begin
  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_email := lower(nullif(btrim(coalesce(p_email, '')), ''));

  -- Rate limits over ten minutes: per studio, per member, per email.
  if (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.created_at > p_at - interval '10 minutes') >= 200
     or (p_member_id is not null and (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.member_id = p_member_id
         and k.created_at > p_at - interval '10 minutes') >= 10)
     or (v_email is not null and (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.buyer_email = v_email
         and k.created_at > p_at - interval '10 minutes') >= 10) then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited',
      'message', 'Too many tries. Try again in a few minutes.');
  end if;

  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (p_at at time zone v_tz)::date;
  select * into c from discount_codes where studio_id = p_studio_id and upper(code) = v_code;
  if c.id is not null then select * into b from discount_code_batches where id = c.batch_id; end if;

  insert into discount_code_checks (studio_id, member_id, buyer_email, ok)
  values (p_studio_id, p_member_id, v_email, c.id is not null);

  if v_code = '' or c.id is null or c.cancelled_at is not null or b.cancelled_at is not null
     or v_today < b.starts_on then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', 'That code isn''t valid.');
  end if;
  if v_today > b.ends_on then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'message', 'That code has expired.');
  end if;
  if (coalesce(p_private, false) and not b.private_sessions)
     or (not coalesce(p_private, false) and (p_plan_id is null or not (p_plan_id = any (b.plan_ids)))) then
    return jsonb_build_object('ok', false, 'reason', 'not_this_plan',
      'message', 'That code doesn''t apply to this plan.');
  end if;

  if b.kind = 'shared' and exists (
       select 1 from discount_code_uses u
        where u.batch_id = b.id and u.status = 'redeemed'
          and (coalesce(u.member_id = p_member_id, false) or coalesce(lower(u.buyer_email) = v_email, false))) then
    return jsonb_build_object('ok', false, 'reason', 'used_by_you', 'message', 'You''ve already used this code.');
  end if;

  select count(*) filter (where u.status = 'redeemed'),
         count(*) filter (where u.status = 'held' and exists (
           select 1 from xendit_purchases xp where xp.id = u.purchase_id
              and xp.status = 'pending' and xp.created_at > p_at - interval '2 hours'))
    into v_used, v_held
    from discount_code_uses u where u.code_id = c.id;

  if b.kind = 'batch' then
    if v_used > 0 then
      return jsonb_build_object('ok', false, 'reason', 'used', 'message', 'That code has already been used.');
    end if;
    if v_held > 0 then
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
  else
    if exists (select 1 from discount_code_uses u join xendit_purchases xp on xp.id = u.purchase_id
                where u.code_id = c.id and u.status = 'held' and xp.status = 'pending'
                  and xp.created_at > p_at - interval '2 hours'
                  and (coalesce(u.member_id = p_member_id, false) or coalesce(lower(u.buyer_email) = v_email, false))) then
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
    if v_used + v_held >= b.max_uses then
      if v_used >= b.max_uses then
        return jsonb_build_object('ok', false, 'reason', 'used', 'message', 'That code has already been used.');
      end if;
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
  end if;

  v_price := promo_sale_cents(p_list_cents, b.pct);
  return jsonb_build_object('ok', true, 'code_id', c.id, 'batch_id', b.id, 'code', c.code,
    'pct', b.pct, 'list_cents', p_list_cents, 'price_cents', v_price,
    'amount_off_cents', p_list_cents - v_price);
end $$;
revoke execute on function discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz) from public, anon, authenticated;
grant  execute on function discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz) to service_role;

-- ---- discount_code_price_run ----------------------------------------------------
-- plan_price_now_run's answer with the code folded in: the lower of the sale
-- price and the code price wins, and only that one is recorded.
create or replace function discount_code_price_run(
  p_plan_id uuid, p_code text, p_member_id uuid, p_email text, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pr jsonb; v_chk jsonb;
begin
  v_pr := plan_price_now_run(p_plan_id, p_at);
  if v_pr is null or nullif(btrim(coalesce(p_code, '')), '') is null then return v_pr; end if;
  v_chk := discount_code_check_run((select studio_id from membership_plans where id = p_plan_id),
             p_code, p_plan_id, false, p_member_id, p_email, (v_pr ->> 'list_cents')::int, p_at);
  if not (v_chk ->> 'ok')::boolean then
    return v_pr || jsonb_build_object('code_ok', false, 'code_reason', v_chk ->> 'reason',
                                      'code_message', v_chk ->> 'message');
  end if;
  if (v_chk ->> 'price_cents')::int >= (v_pr ->> 'price_cents')::int then
    return v_pr || jsonb_build_object('code_ok', true, 'code_applied', false, 'code', v_chk ->> 'code',
      'code_message', 'The sale price is already lower than this code, so the sale price applies.');
  end if;
  return v_pr || jsonb_build_object(
    'price_cents', (v_chk ->> 'price_cents')::int,
    'discount_cents', (v_chk ->> 'amount_off_cents')::int,
    'promotion_id', null, 'promotion_name', null, 'pct', (v_chk ->> 'pct')::int,
    'ends_on', null, 'ends_label', null,
    'code_ok', true, 'code_applied', true, 'code', v_chk ->> 'code',
    'code_id', v_chk ->> 'code_id', 'batch_id', v_chk ->> 'batch_id');
end $$;
revoke execute on function discount_code_price_run(uuid, text, uuid, text, timestamptz) from public, anon, authenticated;
grant  execute on function discount_code_price_run(uuid, text, uuid, text, timestamptz) to service_role;

-- ---- discount_code_hold_run -----------------------------------------------------
create or replace function discount_code_hold_run(
  p_studio_id uuid, p_code_id uuid, p_batch_id uuid, p_member_id uuid, p_email text,
  p_plan_id uuid, p_private_occurrence_id uuid, p_list_cents int, p_amount_off_cents int)
returns uuid
language sql security definer set search_path = public as $$
  insert into discount_code_uses (studio_id, code_id, batch_id, member_id, buyer_email, plan_id,
                                  private_occurrence_id, status, list_cents, amount_off_cents)
  values (p_studio_id, p_code_id, p_batch_id, p_member_id, lower(nullif(btrim(coalesce(p_email, '')), '')),
          p_plan_id, p_private_occurrence_id, 'held', p_list_cents, p_amount_off_cents)
  returning id
$$;
revoke execute on function discount_code_hold_run(uuid, uuid, uuid, uuid, text, uuid, uuid, int, int) from public, anon, authenticated;
grant  execute on function discount_code_hold_run(uuid, uuid, uuid, uuid, text, uuid, uuid, int, int) to service_role;

-- ---- discount_code_return_run: the ONE return helper ----------------------------
-- A payment refunded in full returns its code while the code is still valid.
create or replace function discount_code_return_run(p_payment_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare u discount_code_uses%rowtype; b discount_code_batches%rowtype; c discount_codes%rowtype; v_tz text;
begin
  select u2.* into u from discount_code_uses u2
    join payments p on p.discount_code_use_id = u2.id
   where p.id = p_payment_id and u2.status = 'redeemed'
   for update of u2;
  if u.id is null then return false; end if;
  select * into b from discount_code_batches where id = u.batch_id;
  select * into c from discount_codes where id = u.code_id;
  select timezone into v_tz from studios where id = u.studio_id;
  if b.cancelled_at is not null or c.cancelled_at is not null
     or (now() at time zone v_tz)::date > b.ends_on then
    return false;
  end if;
  update discount_code_uses set status = 'returned', returned_at = now() where id = u.id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (u.studio_id, auth.uid(), 'discount_code.returned', 'discount_codes', u.code_id,
          jsonb_build_object('code', c.code, 'use_id', u.id, 'payment_id', p_payment_id));
  return true;
end $$;
revoke execute on function discount_code_return_run(uuid) from public, anon, authenticated;
grant  execute on function discount_code_return_run(uuid) to service_role;

-- ---- Triggers: the code text on a payment, redeem on success, return on refund --
create or replace function tg_payment_discount_code_fill()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.discount_code_use_id is not null and new.discount_code is null then
    select c.code into new.discount_code
      from discount_code_uses u join discount_codes c on c.id = u.code_id
     where u.id = new.discount_code_use_id;
  end if;
  return new;
end $$;
revoke execute on function tg_payment_discount_code_fill() from public, anon, authenticated;
drop trigger if exists payments_discount_code_fill on payments;
create trigger payments_discount_code_fill before insert or update of discount_code_use_id on payments
  for each row execute function tg_payment_discount_code_fill();

create or replace function tg_payment_discount_code_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if new.discount_code_use_id is null then return new; end if;
  if new.status = 'succeeded' and (tg_op = 'INSERT' or old.status is distinct from 'succeeded') then
    update discount_code_uses
       set status = 'redeemed', redeemed_at = now(), payment_id = new.id,
           member_id = coalesce(member_id, new.member_id)
     where id = new.discount_code_use_id and status = 'held';
    if found then
      select c.code into v_code from discount_code_uses u join discount_codes c on c.id = u.code_id
       where u.id = new.discount_code_use_id;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (new.studio_id, auth.uid(), 'discount_code.redeemed', 'payments', new.id,
              jsonb_build_object('code', v_code, 'use_id', new.discount_code_use_id,
                                 'amount_off_cents', new.discount_cents));
    end if;
  elsif tg_op = 'UPDATE' and new.status = 'refunded' and old.status is distinct from 'refunded' then
    perform discount_code_return_run(new.id);
  end if;
  -- A guest's held payment is attached to the member at claim (Decision 118).
  if tg_op = 'UPDATE' and new.member_id is not null and old.member_id is null then
    update discount_code_uses set member_id = new.member_id
     where id = new.discount_code_use_id and member_id is null;
  end if;
  return new;
end $$;
revoke execute on function tg_payment_discount_code_status() from public, anon, authenticated;
drop trigger if exists payments_discount_code_status on payments;
create trigger payments_discount_code_status after insert or update of status, member_id on payments
  for each row execute function tg_payment_discount_code_status();

create or replace function tg_purchase_discount_code_release()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.discount_code_use_id is not null and new.status in ('failed', 'expired')
     and old.status is distinct from new.status then
    update discount_code_uses set status = 'released', released_at = now()
     where id = new.discount_code_use_id and status = 'held';
  end if;
  return new;
end $$;
revoke execute on function tg_purchase_discount_code_release() from public, anon, authenticated;
drop trigger if exists xendit_purchases_discount_code_release on xendit_purchases;
create trigger xendit_purchases_discount_code_release after update of status on xendit_purchases
  for each row execute function tg_purchase_discount_code_release();

-- ---- discount_code_preview: the price line at checkout and at the desk ----------
-- A member asks for themselves; staff (desk-up) and the class's instructor ask
-- for a member. A private session asks with p_private_type_id. Writes no use.
create or replace function discount_code_preview(
  p_studio_id uuid, p_code text, p_plan_id uuid default null,
  p_member_id uuid default null, p_private_type_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_email text; v_pr jsonb; v_chk jsonb; t private_session_types%rowtype; v_ccy char(3);
begin
  if p_member_id is null then
    select id, email into v_member, v_email from members
     where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
    if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  else
    if not (coalesce(is_desk_up(p_studio_id), false) or auth_instructor_id(p_studio_id) is not null
            or is_service_context()) then
      raise exception 'only staff check a code for a member' using errcode = 'PT403';
    end if;
    select id, email into v_member, v_email from members where id = p_member_id and studio_id = p_studio_id;
    if v_member is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  end if;

  if p_private_type_id is not null then
    select * into t from private_session_types where id = p_private_type_id and studio_id = p_studio_id;
    if t.id is null then raise exception 'no such private session' using errcode = 'PT404'; end if;
    select currency into v_ccy from studios where id = p_studio_id;
    v_chk := discount_code_check_run(p_studio_id, p_code, null, true, v_member, v_email, t.price_cents, now());
    if not (v_chk ->> 'ok')::boolean then
      return jsonb_build_object('list_cents', t.price_cents, 'price_cents', t.price_cents, 'currency', v_ccy,
        'code_ok', false, 'code_reason', v_chk ->> 'reason', 'code_message', v_chk ->> 'message');
    end if;
    return jsonb_build_object('list_cents', t.price_cents, 'price_cents', (v_chk ->> 'price_cents')::int,
      'discount_cents', (v_chk ->> 'amount_off_cents')::int, 'currency', v_ccy,
      'code_ok', true, 'code_applied', true, 'code', v_chk ->> 'code');
  end if;

  if not exists (select 1 from membership_plans where id = p_plan_id and studio_id = p_studio_id) then
    raise exception 'no such plan' using errcode = 'PT404';
  end if;
  return discount_code_price_run(p_plan_id, p_code, v_member, v_email, now());
end $$;
revoke execute on function discount_code_preview(uuid, text, uuid, uuid, uuid) from public, anon;
grant  execute on function discount_code_preview(uuid, text, uuid, uuid, uuid) to authenticated, service_role;

-- ---- Staff: create, list, cancel -----------------------------------------------
create or replace function discount_code_prefix(p_studio_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(left(upper(regexp_replace(slug, '[^A-Za-z0-9]', '', 'g')), 8), ''), 'CODE')
    from studios where id = p_studio_id
$$;
revoke execute on function discount_code_prefix(uuid) from public, anon, authenticated;
grant  execute on function discount_code_prefix(uuid) to service_role;

create or replace function discount_code_random(p_len int)
returns text language plpgsql volatile set search_path = public, extensions as $$
declare a constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; v text := ''; b bytea; i int;
begin
  b := extensions.gen_random_bytes(p_len);
  for i in 0 .. p_len - 1 loop
    v := v || substr(a, (get_byte(b, i) % 31) + 1, 1);
  end loop;
  return v;
end $$;
revoke execute on function discount_code_random(int) from public, anon, authenticated;
grant  execute on function discount_code_random(int) to service_role;

create or replace function discount_code_validate_batch_run(
  p_studio_id uuid, p_name text, p_pct int, p_starts date, p_ends date, p_plan_ids uuid[], p_private boolean)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if btrim(coalesce(p_name, '')) = '' or length(btrim(p_name)) > 60 then return 'Give the code a name.'; end if;
  if p_pct is null or p_pct < 1 or p_pct > 90 then return 'The percent off is a whole number from 1 to 90.'; end if;
  if p_starts is null or p_ends is null or p_ends < p_starts then return 'The end date is before the start date.'; end if;
  if coalesce(array_length(p_plan_ids, 1), 0) = 0 and not coalesce(p_private, false) then
    return 'Choose at least one plan.';
  end if;
  if exists (select 1 from unnest(coalesce(p_plan_ids, '{}'::uuid[])) x
              where not exists (select 1 from membership_plans mp where mp.id = x and mp.studio_id = p_studio_id)) then
    return 'One of those plans is not this studio''s.';
  end if;
  return null;
end $$;
revoke execute on function discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean) from public, anon, authenticated;
grant  execute on function discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean) to service_role;

create or replace function discount_code_create_batch(
  p_studio_id uuid, p_name text, p_pct int, p_count int, p_starts date, p_ends date,
  p_plan_ids uuid[], p_private boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_msg text; v_batch uuid; v_prefix text; v_code text; v_made int := 0; v_try int := 0;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers create discount codes' using errcode = 'PT403';
  end if;
  v_msg := discount_code_validate_batch_run(p_studio_id, p_name, p_pct, p_starts, p_ends, p_plan_ids, p_private);
  if v_msg is null and (p_count is null or p_count < 1 or p_count > 500) then
    v_msg := 'Make between 1 and 500 codes.';
  end if;
  if v_msg is not null then return jsonb_build_object('ok', false, 'message', v_msg); end if;

  insert into discount_code_batches (studio_id, kind, name, pct, starts_on, ends_on, plan_ids, private_sessions, created_by)
  values (p_studio_id, 'batch', btrim(p_name), p_pct, p_starts, p_ends,
          array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[]))), coalesce(p_private, false), auth.uid())
  returning id into v_batch;
  v_prefix := discount_code_prefix(p_studio_id);
  while v_made < p_count and v_try < p_count * 5 loop
    v_try := v_try + 1;
    v_code := v_prefix || '-' || discount_code_random(4) || '-' || discount_code_random(4);
    begin
      insert into discount_codes (studio_id, batch_id, code) values (p_studio_id, v_batch, v_code);
      v_made := v_made + 1;
    exception when unique_violation then null;
    end;
  end loop;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'discount_code.batch_created', 'discount_code_batches', v_batch,
          jsonb_build_object('kind', 'batch', 'name', btrim(p_name), 'pct', p_pct, 'count', v_made,
                             'starts_on', p_starts, 'ends_on', p_ends, 'plan_ids', p_plan_ids,
                             'private_sessions', coalesce(p_private, false)));
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'count', v_made);
end $$;
revoke execute on function discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean) from public, anon;
grant  execute on function discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean) to authenticated, service_role;

create or replace function discount_code_create_shared(
  p_studio_id uuid, p_code text, p_name text, p_pct int, p_starts date, p_ends date,
  p_plan_ids uuid[], p_max_uses int, p_private boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_msg text; v_batch uuid; v_code text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers create discount codes' using errcode = 'PT403';
  end if;
  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  if v_code !~ '^[A-Z0-9]{3,20}$' then
    return jsonb_build_object('ok', false, 'message', 'A code is 3 to 20 letters and digits.');
  end if;
  if exists (select 1 from discount_codes where studio_id = p_studio_id and upper(code) = v_code) then
    return jsonb_build_object('ok', false, 'message', 'That code is already in use. Choose another.');
  end if;
  v_msg := discount_code_validate_batch_run(p_studio_id, coalesce(nullif(btrim(p_name), ''), v_code),
             p_pct, p_starts, p_ends, p_plan_ids, p_private);
  if v_msg is null and (p_max_uses is null or p_max_uses < 1 or p_max_uses > 100000) then
    v_msg := 'Set how many times the code can be used.';
  end if;
  if v_msg is not null then return jsonb_build_object('ok', false, 'message', v_msg); end if;

  insert into discount_code_batches (studio_id, kind, name, pct, starts_on, ends_on, plan_ids,
                                     private_sessions, max_uses, created_by)
  values (p_studio_id, 'shared', coalesce(nullif(btrim(p_name), ''), v_code), p_pct, p_starts, p_ends,
          array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[]))), coalesce(p_private, false),
          p_max_uses, auth.uid())
  returning id into v_batch;
  insert into discount_codes (studio_id, batch_id, code) values (p_studio_id, v_batch, v_code);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'discount_code.batch_created', 'discount_code_batches', v_batch,
          jsonb_build_object('kind', 'shared', 'code', v_code, 'pct', p_pct, 'max_uses', p_max_uses,
                             'starts_on', p_starts, 'ends_on', p_ends, 'plan_ids', p_plan_ids,
                             'private_sessions', coalesce(p_private, false)));
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'code', v_code);
end $$;
revoke execute on function discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean) from public, anon;
grant  execute on function discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean) to authenticated, service_role;

create or replace function discount_code_cancel(p_code_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c discount_codes%rowtype;
begin
  select * into c from discount_codes where id = p_code_id;
  if c.id is null then raise exception 'no such code' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'only owners and managers cancel discount codes' using errcode = 'PT403';
  end if;
  if c.cancelled_at is not null then
    return jsonb_build_object('ok', false, 'message', 'That code is already cancelled.');
  end if;
  if (select kind from discount_code_batches where id = c.batch_id) = 'batch'
     and exists (select 1 from discount_code_uses where code_id = c.id and status in ('redeemed', 'held')) then
    return jsonb_build_object('ok', false, 'message', 'That code has been used, so it can''t be cancelled.');
  end if;
  update discount_codes set cancelled_at = now(), cancelled_by = auth.uid() where id = c.id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (c.studio_id, auth.uid(), 'discount_code.cancelled', 'discount_codes', c.id,
          jsonb_build_object('code', c.code));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function discount_code_cancel(uuid) from public, anon;
grant  execute on function discount_code_cancel(uuid) to authenticated, service_role;

-- The staff list: every batch and shared code with counts; one batch's codes
-- (or a shared code's uses) with their state, who used them, when, the plan
-- and the amount off.
create or replace function discount_code_batches_list(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_today date;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers see discount codes' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', b.id, 'kind', b.kind, 'name', b.name, 'pct', b.pct,
             'starts_on', b.starts_on, 'ends_on', b.ends_on, 'max_uses', b.max_uses,
             'private_sessions', b.private_sessions, 'cancelled', b.cancelled_at is not null,
             'expired', v_today > b.ends_on,
             'code', case when b.kind = 'shared' then (select c.code from discount_codes c where c.batch_id = b.id limit 1) end,
             'codes', (select count(*) from discount_codes c where c.batch_id = b.id),
             'used', (select count(*) from discount_code_uses u where u.batch_id = b.id and u.status = 'redeemed'),
             'plan_names', (select coalesce(jsonb_agg(mp.name order by mp.name), '[]'::jsonb)
                              from membership_plans mp where mp.id = any (b.plan_ids)))
           order by b.created_at desc)
      from discount_code_batches b where b.studio_id = p_studio_id), '[]'::jsonb);
end $$;
revoke execute on function discount_code_batches_list(uuid) from public, anon;
grant  execute on function discount_code_batches_list(uuid) to authenticated, service_role;

create or replace function discount_code_rows(p_batch_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b discount_code_batches%rowtype; v_tz text; v_today date;
begin
  select * into b from discount_code_batches where id = p_batch_id;
  if b.id is null then raise exception 'no such batch' using errcode = 'PT404'; end if;
  if not (coalesce(is_manager_up(b.studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers see discount codes' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = b.studio_id;
  v_today := (now() at time zone v_tz)::date;
  return coalesce((
    select jsonb_agg(r order by r ->> 'sort')
      from (
        select jsonb_build_object(
                 'code_id', c.id, 'code', c.code,
                 'state', case when c.cancelled_at is not null or b.cancelled_at is not null then 'cancelled'
                               when u.id is not null then 'used'
                               when v_today > b.ends_on then 'expired'
                               else 'unused' end,
                 'used_by', coalesce(nullif(btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')), ''), u.buyer_email),
                 'used_email', coalesce(m.email, u.buyer_email),
                 'used_at', u.redeemed_at,
                 'plan', coalesce(mp.name, case when u.private_occurrence_id is not null then 'Private session' end),
                 'amount_off_cents', u.amount_off_cents,
                 'currency', (select currency from studios where id = b.studio_id),
                 'sort', c.code || coalesce(to_char(u.redeemed_at, 'YYYYMMDDHH24MISS'), '')) r
          from discount_codes c
          left join discount_code_uses u on u.code_id = c.id and u.status = 'redeemed'
          left join members m on m.id = u.member_id
          left join membership_plans mp on mp.id = u.plan_id
         where c.batch_id = b.id) x), '[]'::jsonb);
end $$;
revoke execute on function discount_code_rows(uuid) from public, anon;
grant  execute on function discount_code_rows(uuid) to authenticated, service_role;

-- ---- xendit_begin_purchase: re-issued (20260833670000_step12_promotions_return_credit.sql:348), + p_code ----
drop function if exists xendit_begin_purchase(uuid, uuid);
CREATE FUNCTION public.xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid, p_code text DEFAULT NULL::text)
 RETURNS TABLE(purchase_id uuid, amount_cents integer, currency character, credit_applied_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
        v_avail int; v_applied int; v_due int;
        v_pr jsonb; v_price int; v_list int; v_promo uuid; v_disc int;
        v_email text; v_use uuid;
begin
  select id, email into v_member, v_email from members where studio_id = p_studio_id and user_id = auth.uid();
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

  -- Decision 117: the price is fixed now, from the promotion in force.
  -- Decision 120: a code, when given, is checked here; the lower of the sale
  -- price and the code price wins, and only that one is recorded.
  if nullif(btrim(coalesce(p_code, '')), '') is not null then
    v_pr := discount_code_price_run(p_plan_id, p_code, v_member, v_email, now());
    if not coalesce((v_pr ->> 'code_ok')::boolean, false) then
      raise exception '%', v_pr ->> 'code_message' using errcode = 'PT460';
    end if;
  else
    v_pr := plan_price_now_run(p_plan_id, now());
  end if;
  v_price := (v_pr ->> 'price_cents')::int;
  v_promo := nullif(v_pr ->> 'promotion_id', '')::uuid;
  v_list  := case when v_promo is not null then (v_pr ->> 'list_cents')::int end;
  v_disc  := case when v_promo is not null then (v_pr ->> 'discount_cents')::int end;
  if coalesce((v_pr ->> 'code_applied')::boolean, false) then
    v_list := (v_pr ->> 'list_cents')::int;
    v_disc := (v_pr ->> 'discount_cents')::int;
    v_use := discount_code_hold_run(p_studio_id, (v_pr ->> 'code_id')::uuid, (v_pr ->> 'batch_id')::uuid,
               v_member, v_email, p_plan_id, null, v_list, v_disc);
  end if;

  v_avail := reservation_credit_available(p_studio_id, v_member);

  -- Decision 103(f): credit covers the whole total. No Xendit, no floor; complete
  -- now and return due 0 so the app lands straight on the success screen.
  if v_avail >= v_price then
    insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                  renews_membership_id, credit_applied_cents,
                                  list_price_cents, promotion_id, discount_cents, discount_code_use_id)
    values (p_studio_id, v_member, p_plan_id, v_price, mp.currency, v_renew, v_price,
            v_list, v_promo, v_disc, v_use)
    returning id into v_id;
    update discount_code_uses set purchase_id = v_id where id = v_use;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, mp.currency, v_price;
    return;
  end if;

  -- Partial (or no) credit: cap so the online payment is >= the processor minimum.
  v_applied := least(greatest(v_avail, 0), greatest(v_price - 2000, 0));
  v_due := v_price - v_applied;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                renews_membership_id, credit_applied_cents,
                                list_price_cents, promotion_id, discount_cents, discount_code_use_id)
  values (p_studio_id, v_member, p_plan_id, v_due, mp.currency, v_renew, v_applied,
          v_list, v_promo, v_disc, v_use)
  returning id into v_id;
  update discount_code_uses set purchase_id = v_id where id = v_use;

  return query select v_id, v_due, mp.currency, v_applied;
end $function$;
revoke execute on function xendit_begin_purchase(uuid, uuid, text) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid, text) to authenticated, service_role;

-- ---- plan_buy_begin: re-issued (20260833710000:233), + p_code, p_preview ----
-- Still the fifteenth anon function, so it is dropped and recreated (the
-- argument list and the returned columns change) and the anon grant re-applied.
-- A preview (p_preview) checks a code and returns the price, writing no
-- purchase; a real begin with a code holds it for this checkout.
drop function if exists plan_buy_begin(uuid, uuid, text, text, text);
create function plan_buy_begin(
  p_studio_id uuid, p_plan_id uuid,
  p_buyer_name text default null, p_buyer_email text default null, p_buyer_phone text default null,
  p_code text default null, p_preview boolean default false
) returns table(purchase_id uuid, amount_cents int, currency char(3),
                secret_key_ciphertext text, test_mode boolean, apple_pay_verified boolean, plan_name text,
                list_cents int, discount_cents int, code_applied boolean, code text, code_message text)
language plpgsql security definer set search_path = public as $$
declare mp membership_plans%rowtype; ss studio_settings%rowtype; v_country text;
        v_email text; v_name text; v_phone text; v_pr jsonb; v_price int; v_promo uuid;
        v_list int; v_disc int; v_id uuid; v_use uuid; v_has_code boolean;
begin
  if not exists (select 1 from studios where id = p_studio_id and status = 'active') then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;
  select * into mp from membership_plans where id = p_plan_id and studio_id = p_studio_id;
  if mp.id is null or mp.status <> 'active' or mp.visibility <> 'public'
     or mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  select * into ss from studio_settings where studio_id = p_studio_id;
  if mp.max_active_members is not null and coalesce(ss.seat_caps_enabled, false)
     and plan_seats_taken(mp.id) >= mp.max_active_members then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  v_name := nullif(btrim(coalesce(p_buyer_name, '')), '');
  v_email := lower(nullif(btrim(coalesce(p_buyer_email, '')), ''));
  v_has_code := nullif(btrim(coalesce(p_code, '')), '') is not null;

  if not coalesce(p_preview, false) then
    if v_name is null or length(v_name) > 120 then
      raise exception 'a name is needed' using errcode = 'PT422';
    end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
      raise exception 'an email address is needed' using errcode = 'PT422';
    end if;
    select country into v_country from studios where id = p_studio_id;
    v_phone := normalise_phone(p_buyer_phone, v_country);
    if nullif(btrim(coalesce(v_phone, '')), '') is null
       or (v_country = 'PH' and v_phone !~ '^\+639[0-9]{9}$')
       or (coalesce(v_country,'') <> 'PH'
           and length(regexp_replace(coalesce(v_phone,''), '[^0-9]', '', 'g')) not between 7 and 15) then
      raise exception 'that does not look like a mobile number' using errcode = 'PT422';
    end if;

    if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
          and xp.buyer_email is not null and xp.created_at > now() - interval '1 minute') >= 10 then
      raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
    end if;
    if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
          and lower(xp.buyer_email) = v_email and xp.created_at > now() - interval '1 minute') >= 3 then
      raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
    end if;
  elsif v_email is not null and (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254) then
    v_email := null;
  end if;

  -- Decision 117: the price is fixed now, from the promotion in force.
  -- Decision 120: with a code, the lower of the sale and the code price.
  if v_has_code then
    v_pr := discount_code_price_run(p_plan_id, p_code, null, v_email, now());
    if not coalesce((v_pr ->> 'code_ok')::boolean, false) then
      if coalesce(p_preview, false) then
        return query select null::uuid, (v_pr ->> 'price_cents')::int, mp.currency, null::text, null::boolean,
                            null::boolean, mp.name, (v_pr ->> 'list_cents')::int,
                            (v_pr ->> 'discount_cents')::int, false, null::text, v_pr ->> 'code_message';
        return;
      end if;
      raise exception '%', v_pr ->> 'code_message' using errcode = 'PT460';
    end if;
  else
    v_pr := plan_price_now_run(p_plan_id, now());
  end if;
  v_price := (v_pr ->> 'price_cents')::int;
  v_promo := nullif(v_pr ->> 'promotion_id', '')::uuid;
  v_list  := case when v_promo is not null then (v_pr ->> 'list_cents')::int end;
  v_disc  := case when v_promo is not null then (v_pr ->> 'discount_cents')::int end;
  if coalesce((v_pr ->> 'code_applied')::boolean, false) then
    v_list := (v_pr ->> 'list_cents')::int;
    v_disc := (v_pr ->> 'discount_cents')::int;
  end if;

  if coalesce(p_preview, false) then
    return query select null::uuid, v_price, mp.currency, null::text, null::boolean, null::boolean, mp.name,
                        (v_pr ->> 'list_cents')::int, coalesce(v_disc, 0),
                        coalesce((v_pr ->> 'code_applied')::boolean, false), v_pr ->> 'code',
                        v_pr ->> 'code_message';
    return;
  end if;

  if coalesce((v_pr ->> 'code_applied')::boolean, false) then
    v_use := discount_code_hold_run(p_studio_id, (v_pr ->> 'code_id')::uuid, (v_pr ->> 'batch_id')::uuid,
               null, v_email, p_plan_id, null, v_list, v_disc);
  end if;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                list_price_cents, promotion_id, discount_cents,
                                buyer_email, buyer_name, buyer_phone, discount_code_use_id)
  values (p_studio_id, null, p_plan_id, v_price, mp.currency, v_list, v_promo, v_disc,
          v_email, v_name, v_phone, v_use)
  returning id into v_id;
  update discount_code_uses set purchase_id = v_id where id = v_use;

  return query
    select v_id, v_price, mp.currency, spp.secret_key_ciphertext, spp.test_mode,
           coalesce(ss.gift_apple_pay_verified, false), mp.name,
           (v_pr ->> 'list_cents')::int, coalesce(v_disc, 0),
           coalesce((v_pr ->> 'code_applied')::boolean, false), v_pr ->> 'code', v_pr ->> 'code_message'
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;
revoke execute on function plan_buy_begin(uuid, uuid, text, text, text, text, boolean) from public;
grant  execute on function plan_buy_begin(uuid, uuid, text, text, text, text, boolean) to anon, authenticated, service_role;

-- ---- record_manual_payment_run: re-issued (20260833680000_step12b_flex_state_rescue_recurring_promo.sql:920), + p_code ----
drop function if exists record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text);
create function record_manual_payment_run(
  p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text,
  p_plan_id uuid default null, p_booking_id uuid default null, p_currency char default null,
  p_method_note text default null, p_reference text default null,
  p_paid_at timestamptz default now(), p_description text default null,
  p_code text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;
  v_pr jsonb; v_list int; v_promo uuid; v_disc int;
  v_code jsonb; v_use uuid; v_amount int := p_amount_cents; v_email text;
begin
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'an amount is needed' using errcode = 'PT400';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  select coalesce(p_currency, s.currency) into v_currency
    from studios s where s.id = p_studio_id;

  -- Decision 120: a code at the desk, checked before anything is written. A
  -- valid code sets the amount to the code price (or the sale price if lower).
  if nullif(btrim(coalesce(p_code, '')), '') is not null then
    if p_kind <> 'plan' or p_plan_id is null then
      raise exception 'That code doesn''t apply to this plan.' using errcode = 'PT460';
    end if;
    select email into v_email from members where id = p_member_id;
    v_code := discount_code_price_run(p_plan_id, p_code, p_member_id, v_email, now());
    if not coalesce((v_code ->> 'code_ok')::boolean, false) then
      raise exception '%', v_code ->> 'code_message' using errcode = 'PT460';
    end if;
    v_amount := (v_code ->> 'price_cents')::int;
  end if;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
    select ms.id into v_renewing
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.member_id = p_member_id
       and ms.plan_id = p_plan_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;

    if v_renewing is not null then
      v_ms := v_renewing;
      -- The UNGUARDED twin: record_manual_payment_run is also reached from the
      -- instructor desk (sell_plan_at_desk), where the caller is not desk/service
      -- and advance_membership_period's own guard would refuse. The desk/scope
      -- boundary is enforced by the caller (is_desk_up wrapper / instructor_scope).
      v_renewal := advance_membership_period_run(v_renewing);
    else
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                v_amount, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  -- Decision 117: the promotion is recorded only when the amount IS the sale
  -- price; any other typed amount is a manual price, recorded as typed.
  if coalesce((v_code ->> 'code_applied')::boolean, false) then
    v_list := (v_code ->> 'list_cents')::int;
    v_disc := (v_code ->> 'discount_cents')::int;
    v_use := discount_code_hold_run(p_studio_id, (v_code ->> 'code_id')::uuid, (v_code ->> 'batch_id')::uuid,
               p_member_id, v_email, p_plan_id, null, v_list, v_disc);
    if v_ms is not null and v_renewing is null then
      update memberships ms set price_cents = v_list
        from membership_plans pl
       where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
    end if;
  elsif p_kind = 'plan' and p_plan_id is not null then
    v_pr := plan_price_now_run(p_plan_id, now());
    if nullif(v_pr ->> 'promotion_id', '') is not null
       and v_amount = (v_pr ->> 'price_cents')::int then
      v_promo := (v_pr ->> 'promotion_id')::uuid;
      v_list  := (v_pr ->> 'list_cents')::int;
      v_disc  := (v_pr ->> 'discount_cents')::int;
      -- Decision 117(a): a new recurring membership sold on sale keeps the
      -- list price as its rate (a renewal never changes the rate).
      if v_ms is not null and v_renewing is null then
        update memberships ms set price_cents = v_list
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by, list_price_cents, promotion_id, discount_cents, discount_code_use_id
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, v_amount, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid(), v_list, v_promo, v_disc, v_use
  ) returning id into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    'renewed', v_renewal
  );
end $$;
revoke execute on function record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text) from public, anon, authenticated;
grant  execute on function record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text) to service_role;

-- ---- record_manual_payment: re-issued (20260832970000:244), + p_code ----
drop function if exists record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text);
create function public.record_manual_payment(p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text, p_plan_id uuid DEFAULT NULL::uuid, p_booking_id uuid DEFAULT NULL::uuid, p_currency character DEFAULT NULL::bpchar, p_method_note text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_paid_at timestamp with time zone DEFAULT now(), p_description text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a payment' using errcode = 'PT403';
  end if;
  return record_manual_payment_run(p_studio_id, p_member_id, p_kind, p_amount_cents, p_method,
    p_plan_id, p_booking_id, p_currency, p_method_note, p_reference, p_paid_at, p_description, p_code);
end $function$;
revoke execute on function record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text) from public, anon;
grant  execute on function record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text) to authenticated, service_role;

-- ---- sell_plan_at_desk: re-issued (20260833670000_step12_promotions_return_credit.sql:650), + p_code ----
drop function if exists sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean);
create function sell_plan_at_desk(p_occurrence uuid, p_member uuid, p_plan uuid,
                                             p_method text, p_reference text, p_use_for_today boolean,
                                             p_code text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope text; v_occ class_occurrences%rowtype; mp membership_plans%rowtype;
        v_res jsonb; v_ms uuid; v_seat bookings%rowtype;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then return jsonb_build_object('ok', false, 'reason', v_scope); end if;
  select * into v_occ from class_occurrences where id = p_occurrence;

  if p_method not in ('gcash','cash','card_terminal') then
    return jsonb_build_object('ok', false, 'reason', 'unknown payment method');
  end if;
  if not exists (select 1 from bookings where occurrence_id = p_occurrence and member_id = p_member
                  and status in ('booked','attended','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class' );
  end if;
  select * into mp from membership_plans
   where id = p_plan and studio_id = v_occ.studio_id and status = 'active' and visibility = 'public';
  if not found then return jsonb_build_object('ok', false, 'reason', 'plan not for sale here'); end if;

  v_res := record_manual_payment_run(v_occ.studio_id, p_member, 'plan',
             (plan_price_now_run(p_plan, now()) ->> 'price_cents')::int, p_method,
             p_plan, null, null, null, nullif(btrim(coalesce(p_reference,'')), ''),
             now(), null, p_code);
  v_ms := nullif(v_res ->> 'membership_id', '')::uuid;

  -- Use it for today: pay the member's unpaid drop-in in THIS class from the new
  -- plan (Decision 73b apply-on-activation), so its due becomes zero.
  if p_use_for_today and v_ms is not null then
    select * into v_seat from bookings
     where occurrence_id = p_occurrence and member_id = p_member and payment_source = 'drop_in'
       and status in ('booked','attended')
       and not exists (select 1 from payments p where p.booking_id = bookings.id and p.status in ('succeeded','partially_refunded'))
     limit 1;
    if found then perform apply_plan_to_unpaid(v_occ.studio_id, p_member, v_ms); end if;
  end if;

  return jsonb_build_object('ok', true, 'membership_id', v_ms, 'payment_id', v_res ->> 'payment_id',
    'renewed', v_res -> 'renewed');
end $$;
revoke execute on function sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean, text) from public, anon;
grant  execute on function sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean, text) to authenticated, service_role;

-- ---- xendit_activate_success_internal: re-issued (20260833710000_decision118_buy_without_account.sql:576), the code on the payment ----
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
        gc gift_cards%rowtype; v_code text; v_prov payment_provider; v_src text; v_ref text; v_send timestamptz;
        v_held boolean := false; v_guest uuid; v_attached boolean := false; v_act jsonb;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  -- A full-credit (Decision 103(f)) completion: the payment row is source credit,
  -- provider manual, no processor reference.
  v_prov := case when p_source = 'credit' then 'manual'::payment_provider else 'xendit'::payment_provider end;
  v_src  := nullif(p_source, 'xendit');
  v_ref  := case when p_source = 'credit' then null else nullif(p_payment_id, '') end;

  if p.booking_id is not null then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Reservation fee', now())
    returning id into v_pay_id;
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);
      else
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.gift_card_id is not null then
    -- Decision 110: issue the gift card. Mint the code, record the sale (a real
    -- payment, so it counts in revenue once; linked by gift_card_id). Email the
    -- buyer at once; schedule the recipient for the delivery date (now when none).
    select * into gc from gift_cards where id = p.gift_card_id for update;
    v_code := gift_code(p.studio_id);
    -- Decision 110(a): the composited card image (amount + code over the studio's
    -- card) is served by the member host's next/og route; its path is stored on
    -- the card at issue and carried on gift_card_sent.
    update gift_cards set status = 'active', code = v_code, issued_at = now(),
           card_image_path = '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text
     where id = gc.id and status in ('pending', 'active');

    insert into payments (studio_id, member_id, gift_card_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, gc.id, 'gift_card', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Gift card', now());

    perform queue_notification(p.studio_id, gc.buyer_member_id, 'gift_card_receipt',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_receipt:' || gc.id::text);

    v_send := case
      when gc.delivery_date is null then now()
      else greatest(now(),
        ((gc.delivery_date::text || ' 08:00')::timestamp
          at time zone (select timezone from studios where id = p.studio_id))) end;
    perform queue_notification(p.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
      jsonb_build_object('to_email', gc.recipient_email,
        'recipient_name', coalesce(gc.recipient_name, 'there'),
        'buyer_name', coalesce(gc.buyer_name, 'A friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'message', coalesce(gc.message, ''),
        'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
          else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
        'card_image_url', member_portal_url(p.studio_id,
          '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text),
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

  elsif p.private_occurrence_id is not null then
    -- Decision 116: a full-paid private. Record the 'private' payment against the
    -- booker's seat (so Sales buckets it by the occurrence), then confirm the
    -- session at once (commit, flip seats, tell everyone, write the flat pay line).
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at,
                          list_price_cents, discount_cents, discount_code_use_id)
    select p.studio_id, p.member_id, (select b.id from bookings b
             where b.occurrence_id = p.private_occurrence_id and b.payment_source = 'private'
             order by b.created_at limit 1),
           'private', p.amount_cents, p.currency, 'succeeded', v_prov, v_src, v_ref,
           'Private session', now(), p.list_price_cents, p.discount_cents, p.discount_code_use_id
    returning id into v_pay_id;
    select * into v_occ from class_occurrences where id = p.private_occurrence_id;
    if v_occ.status = 'scheduled' and v_occ.starts_at > now() then
      perform private_confirm_run(p.private_occurrence_id);
    else
      -- a late success on a private already released (expired session): the
      -- money is never lost, it lands as account credit (the 103(e) rule).
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'private_refund', v_pay_id);
    end if;

  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', v_prov,
            v_src, v_ref, prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    -- Decision 118: a plan bought by somebody without an account. An existing
    -- account with that email (a login, in this studio) gets the plan at once,
    -- unless it is an intro offer, whose eligibility is decided at claim, signed
    -- in. Everyone else's plan is held under the email until they claim it.
    if p.member_id is null and p.buyer_email is not null then
      -- The login's own email must match and be verified (claim requires a
      -- verified email; an unverified sign-up never receives a paid plan).
      select m.id into v_guest from members m
        join auth.users u on u.id = m.user_id
       where m.studio_id = p.studio_id and m.deleted_at is null
         and u.email_confirmed_at is not null
         and lower(u.email) = lower(p.buyer_email)
       order by m.created_at limit 1;
      if v_guest is not null and not plan_is_intro_offer(p.plan_id) then
        p.member_id := v_guest;
        update xendit_purchases
           set member_id = v_guest, guest_status = 'claimed', claimed_at = now(), claimed_member_id = v_guest
         where id = p.id;
        -- The buyer's phone fills an empty phone, which runs the free-first
        -- same-person check (members_phone_recheck), as at claim.
        update members set phone = p.buyer_phone
         where id = v_guest and nullif(btrim(coalesce(phone, '')), '') is null;
        v_attached := true;
      else
        insert into payments (studio_id, member_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents, discount_code_use_id)
        select p.studio_id, null, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents, p.discount_code_use_id
          from membership_plans mp where mp.id = p.plan_id
        returning id into v_pay_id;
        update xendit_purchases set guest_status = 'held', guest_payment_id = v_pay_id where id = p.id;
        perform queue_notification(p.studio_id, null, 'plan_waiting_claim',
          plan_guest_email_payload(p.id), 'plan_waiting_claim:' || p.id::text);
        v_held := true;
      end if;
    end if;

    if not v_held then
      v_act := plan_purchase_activate_run(p.id, p.member_id);
      v_group := nullif(v_act ->> 'group_purchase_id', '')::uuid;
      v_ms := nullif(v_act ->> 'membership_id', '')::uuid;
      if v_group is not null then
        insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents, discount_code_use_id)
        select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents, p.discount_code_use_id
          from membership_plans mp where mp.id = p.plan_id;
      else
        insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents, discount_code_use_id)
        select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents, p.discount_code_use_id
          from membership_plans mp where mp.id = p.plan_id;
      end if;
      if v_attached then
        perform queue_notification(p.studio_id, p.member_id, 'plan_in_account',
          plan_guest_email_payload(p.id), 'plan_in_account:' || p.id::text);
      end if;
    end if;
  end if;

  -- ONE consume: a plan/product (and reservation, when not via reserve_free_first)
  -- purchase consumes any reservation/gift credit applied at begin. A gift sale
  -- never carries credit_applied, so this is a no-op there.
  if p.credit_applied_cents > 0 then
    perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
  end if;

  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;
revoke execute on function xendit_activate_success_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text, text) to service_role;

-- ---- plan_purchase_activate_run: re-issued (20260833710000_decision118_buy_without_account.sql:189), a code keeps the list rate too ----
create or replace function plan_purchase_activate_run(p_purchase_id uuid, p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_group uuid; v_is_group boolean;
begin
  select * into p from xendit_purchases where id = p_purchase_id;
  if p.id is null or p.plan_id is null then raise exception 'no such plan purchase' using errcode = 'PT404'; end if;
  p.member_id := p_member_id;
  -- Moved verbatim from xendit_activate_success_internal's plan branch
  -- (20260833680000) so the webhook and the Decision 118 claim activate a paid
  -- plan the same way. The payment row stays with each caller.
  select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
  if v_is_group then
    v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
  else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
      -- Decision 117(a): a recurring membership bought on sale keeps the list
      -- price as its rate; the discount belongs to this period's payment.
      if (p.promotion_id is not null or p.discount_code_use_id is not null) and p.list_price_cents is not null then
        update memberships ms set price_cents = p.list_price_cents
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);
  end if;
  return jsonb_build_object('membership_id', v_ms, 'group_purchase_id', v_group);
end $$;
revoke execute on function plan_purchase_activate_run(uuid, uuid) from public, anon, authenticated;
grant  execute on function plan_purchase_activate_run(uuid, uuid) to service_role;

-- ---- private_book_run: re-issued (20260833600000_decision116b_private_keeps_coach.sql:118), + p_code ----
drop function if exists private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text);
CREATE FUNCTION public.private_book_run(p_member_id uuid, p_type_id uuid, p_instructor_id uuid, p_starts_at timestamp with time zone, p_companions jsonb, p_mode text, p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t private_session_types%rowtype; ss studio_settings%rowtype; v_tz text;
  v_member members%rowtype; v_studio uuid; v_coach uuid; v_room uuid; v_ends timestamptz;
  v_loc uuid; v_occ uuid; v_seat_status booking_status; v_booker_booking uuid;
  v_ccy char(3); v_pack uuid; v_purchase uuid; v_conflict text; v_mode text;
  v_ncomp int; v_comp jsonb; v_cmember uuid; v_now timestamptz := now();
  v_emails text[]; v_e text; v_credit int; v_pay uuid;
  v_rep uuid; v_rep_coach uuid;
  v_buf int; v_opt record; v_any_coach uuid;
  v_code jsonb; v_price int; v_use uuid;
begin
  select * into t from private_session_types where id = p_type_id and active;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  v_studio := t.studio_id;
  select * into ss from studio_settings where studio_id = v_studio;
  if not coalesce(ss.private_sessions_enabled, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled'); end if;
  select * into v_member from members where id = p_member_id and studio_id = v_studio and deleted_at is null;
  if v_member.id is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  select timezone, currency into v_tz, v_ccy from studios where id = v_studio;
  v_ends := p_starts_at + make_interval(mins => t.duration_min);
  v_mode := coalesce(p_mode, 'xendit');
  if v_mode not in ('xendit', 'pack', 'credit', 'desk') then
    return jsonb_build_object('ok', false, 'reason', 'bad_pay_mode'); end if;

  -- Decision 120: a code on the private session pay step, checked before
  -- anything is written.
  v_price := t.price_cents;
  if v_mode = 'xendit' and nullif(btrim(coalesce(p_code, '')), '') is not null then
    v_code := discount_code_check_run(v_studio, p_code, null, true, p_member_id, v_member.email,
                                      t.price_cents, now());
    if not (v_code ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', 'code', 'message', v_code ->> 'message');
    end if;
    v_price := (v_code ->> 'price_cents')::int;
  end if;

  -- companions: exactly people - 1, each a distinct email that is not the booker
  v_ncomp := coalesce(jsonb_array_length(p_companions), 0);
  if v_ncomp <> t.people - 1 then
    return jsonb_build_object('ok', false, 'reason', 'wrong_companion_count', 'need', t.people - 1); end if;
  v_emails := array[lower(btrim(coalesce(v_member.email, '')))];
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    v_e := lower(btrim(coalesce(v_comp->>'email', '')));
    if v_e not like '%_@_%' or coalesce(nullif(btrim(v_comp->>'name'), ''), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'companion_details'); end if;
    if v_e = any(v_emails) then
      return jsonb_build_object('ok', false, 'reason', 'companion_duplicate'); end if;
    v_emails := v_emails || v_e;
  end loop;

  -- lead time (a desk booking skips it: staff may book at short notice), hours
  if v_mode <> 'desk'
     and p_starts_at < v_now + make_interval(hours => coalesce(ss.private_lead_time_hours, 24)) then
    return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if p_starts_at <= v_now then return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if ss.open_time is null or ss.close_time is null
     or (p_starts_at at time zone v_tz)::time < ss.open_time
     or (v_ends at time zone v_tz)::time > ss.close_time
     or (p_starts_at at time zone v_tz)::date <> (v_ends at time zone v_tz)::date then
    return jsonb_build_object('ok', false, 'reason', 'outside_hours'); end if;

  -- Decision 116(a)/(b): a free room over [start - buffer, end + buffer] is used
  -- with any available private coach. With no free room, a room whose only class
  -- then is empty and replaceable (private_replace_ok) is used, and only with
  -- THAT class's own coach (116 b): no coach is ever displaced. A replacing
  -- private records the class and takes no room until it is confirmed; a pending
  -- replacement (room null) holds the room of the class it targets.
  v_buf := coalesce(ss.private_buffer_minutes, 10);
  select r.id into v_room
    from rooms r
    cross join lateral (
        select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = p_starts_at) as aligned
          from class_occurrences o
         where o.status <> 'cancelled'
           and (o.room_id = r.id
                or (o.room_id is null and o.replaces_occurrence_id in
                      (select x.id from class_occurrences x where x.room_id = r.id)))
           and tstzrange(o.starts_at, o.ends_at)
               && tstzrange(p_starts_at - make_interval(mins => v_buf),
                            v_ends + make_interval(mins => v_buf))) ov
   where r.studio_id = v_studio and r.status = 'active' and ov.n = 0
   order by r.name limit 1;

  if v_room is null then
    for v_opt in
      select r.id as rid, ov.rep,
             (select z.instructor_id from class_occurrences z where z.id = ov.rep) as rcoach
        from rooms r
        cross join lateral (
        select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = p_starts_at) as aligned
          from class_occurrences o
         where o.status <> 'cancelled'
           and (o.room_id = r.id
                or (o.room_id is null and o.replaces_occurrence_id in
                      (select x.id from class_occurrences x where x.room_id = r.id)))
           and tstzrange(o.starts_at, o.ends_at)
               && tstzrange(p_starts_at - make_interval(mins => v_buf),
                            v_ends + make_interval(mins => v_buf))) ov
       where r.studio_id = v_studio and r.status = 'active'
         and ov.n = 1 and ov.aligned and private_replace_ok(ov.rep, p_starts_at)
       order by r.name
    loop
      if v_any_coach is null then v_any_coach := v_opt.rcoach; end if;
      if v_opt.rcoach is not null
         and (p_instructor_id is null or v_opt.rcoach = p_instructor_id)
         and exists (select 1 from instructors i where i.id = v_opt.rcoach and i.status = 'active'
                       and coalesce(i.teaches_privates, false))
         and instructor_available_at_run(v_opt.rcoach, p_starts_at, v_ends)
         and not exists (select 1 from class_occurrences x where x.instructor_id = v_opt.rcoach
                           and x.status <> 'cancelled' and x.id <> v_opt.rep
                           and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
        v_room := v_opt.rid; v_rep := v_opt.rep; v_rep_coach := v_opt.rcoach;
        exit;
      end if;
    end loop;
    if v_room is null then
      -- the time is an empty class with another coach: name them
      if p_instructor_id is not null and v_any_coach is not null and v_any_coach <> p_instructor_id then
        raise exception 'That time is with %. Pick that coach or another time.',
          (select split_part(display_name, ' ', 1) from instructors where id = v_any_coach)
          using errcode = 'PT409', detail = 'private_coach_mismatch';
      end if;
      return jsonb_build_object('ok', false,
        'reason', case when v_any_coach is null then 'no_room' else 'coach_unavailable' end);
    end if;
    v_coach := v_rep_coach;
  elsif p_instructor_id is not null then
    -- a free room: the chosen coach
    if not exists (select 1 from instructors i where i.id = p_instructor_id and i.studio_id = v_studio
                    and i.status = 'active' and coalesce(i.teaches_privates, false))
       or not instructor_available_at_run(p_instructor_id, p_starts_at, v_ends) then
      return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
    if exists (select 1 from class_occurrences x where x.instructor_id = p_instructor_id
                 and x.status <> 'cancelled'
                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
      return jsonb_build_object('ok', false, 'reason', 'coach_busy'); end if;
    v_coach := p_instructor_id;
  else
    -- a free room, no coach chosen: the first available private coach
    select i.id into v_coach from instructors i
      where i.studio_id = v_studio and i.status = 'active' and coalesce(i.teaches_privates, false)
        and instructor_available_at_run(i.id, p_starts_at, v_ends)
        and not exists (select 1 from class_occurrences x where x.instructor_id = i.id
                          and x.status <> 'cancelled'
                          and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends))
      order by i.display_name limit 1;
    if v_coach is null then return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
  end if;

  select id into v_loc from locations where studio_id = v_studio and is_primary order by created_at limit 1;

  -- a Xendit private the member's account credit fully covers completes from credit
  if v_mode = 'xendit' and reservation_credit_available(v_studio, p_member_id) >= t.price_cents then
    v_mode := 'credit';
  end if;
  if v_mode = 'credit' and reservation_credit_available(v_studio, p_member_id) < t.price_cents then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_credit'); end if;
  if v_mode = 'xendit' and not exists (select 1 from studio_payment_providers
       where studio_id = v_studio and provider = 'xendit') then
    return jsonb_build_object('ok', false, 'reason', 'no_provider'); end if;
  if v_mode = 'desk' and coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_method'); end if;

  -- a pack resolves up front so a missing pack fails before creating anything
  if v_mode = 'pack' then
    if t.people <> 1 then return jsonb_build_object('ok', false, 'reason', 'pack_1to1_only'); end if;
    v_pack := private_pack_consume(p_member_id, v_studio);
    if v_pack is null then return jsonb_build_object('ok', false, 'reason', 'no_pack_credit'); end if;
  end if;

  v_seat_status := case when v_mode = 'xendit' then 'pending_payment' else 'booked' end::booking_status;

  begin
    insert into class_occurrences (studio_id, location_id, class_type_id, name, instructor_id,
      room_id, capacity, starts_at, ends_at, guarantee_tier, flex, is_private, private_type_id,
      hidden_from_members, replaces_occurrence_id)
    values (v_studio, v_loc, null, t.name || ' · ' || coalesce(nullif(v_member.preferred_name, ''), v_member.first_name),
      v_coach, case when v_rep is null then v_room end, t.people, p_starts_at, v_ends, 'always', false, true, t.id, true,
      v_rep)
    returning id into v_occ;
  exception when exclusion_violation then
    get stacked diagnostics v_conflict = constraint_name;
    if v_pack is not null then
      update memberships set credits_remaining = credits_remaining + 1 where id = v_pack;
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
      select v_studio, p_member_id, v_pack, 1, 'booking',
             (select credits_remaining from memberships where id = v_pack);
    end if;
    return jsonb_build_object('ok', false,
      'reason', case when v_conflict = 'occ_room_no_overlap' then 'room_busy' else 'coach_busy' end);
  end;

  -- the private's own private_confirmed is the confirmation; the ordinary
  -- booking_confirmed must not also go (the walk-in flag, txn-local).
  perform set_config('studiior.suppress_booking_email', '1', true);
  -- the booker's seat
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
  values (v_studio, v_occ, p_member_id, v_seat_status,
          (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source,
          'private', v_pack)
  returning id into v_booker_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = v_occ;

  -- companion seats: resolve or create each as a lead; part of the paid private
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    select id into v_cmember from members where studio_id = v_studio
      and lower(email) = lower(btrim(v_comp->>'email')) and deleted_at is null;
    if v_cmember is null then
      insert into members (studio_id, first_name, last_name, email, status, source)
      values (v_studio, split_part(btrim(v_comp->>'name'), ' ', 1), name_last_part(btrim(v_comp->>'name')),
              lower(btrim(v_comp->>'email')), 'lead', 'private_companion')
      returning id into v_cmember;
    end if;
    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
    values (v_studio, v_occ, v_cmember, v_seat_status,
            (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source, 'private');
    update class_occurrences set booked_count = booked_count + 1 where id = v_occ;
  end loop;
  perform set_config('studiior.suppress_booking_email', '', true);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'private.booked', 'class_occurrences', v_occ,
          jsonb_build_object('type', t.name, 'people', t.people, 'mode', v_mode,
                             'member_id', p_member_id, 'starts_at', p_starts_at,
                             'replaces_occurrence_id', v_rep));

  if v_mode = 'xendit' then
    if v_code is not null then
      v_use := discount_code_hold_run(v_studio, (v_code ->> 'code_id')::uuid, (v_code ->> 'batch_id')::uuid,
                 p_member_id, v_member.email, null, v_occ, t.price_cents, t.price_cents - v_price);
    end if;
    insert into xendit_purchases (studio_id, member_id, private_occurrence_id, amount_cents, currency,
                                  list_price_cents, discount_cents, discount_code_use_id)
    values (v_studio, p_member_id, v_occ, v_price, v_ccy,
            case when v_use is not null then t.price_cents end,
            case when v_use is not null then t.price_cents - v_price end, v_use)
    returning id into v_purchase;
    update discount_code_uses set purchase_id = v_purchase where id = v_use;
    return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', false,
      'purchase_id', v_purchase, 'amount_cents', v_price, 'currency', v_ccy);
  end if;

  if v_mode = 'credit' then
    v_credit := consume_reservation_credit(v_studio, p_member_id, t.price_cents);
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', 'credit', 'Private session (account credit)', now());
  elsif v_mode = 'desk' then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, method, reference, recorded_by, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', p_method, nullif(btrim(coalesce(p_reference, '')), ''),
            auth.uid(), 'Private session', now())
    returning id into v_pay;
  end if;
  perform private_confirm_run(v_occ);
  -- Decision 116(a): the class it replaces was booked in the meantime, so the
  -- private was refused at confirm and the money came back.
  if (select status from class_occurrences where id = v_occ) = 'cancelled' then
    return jsonb_build_object('ok', false, 'reason', 'time_taken', 'occurrence_id', v_occ);
  end if;
  return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', true, 'mode', v_mode);
end $function$;
revoke execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text) from public, anon, authenticated;
grant  execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text) to service_role;

-- ---- private_book: re-issued (20260833580000:506), + p_code ----
drop function if exists private_book(uuid, uuid, timestamptz, jsonb, text);
create function private_book(
  p_type_id uuid, p_instructor_id uuid, p_starts_at timestamptz,
  p_companions jsonb default '[]'::jsonb, p_pay_mode text default 'xendit', p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_member uuid;
begin
  select studio_id into v_studio from private_session_types where id = p_type_id;
  if v_studio is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  select id into v_member from members where studio_id = v_studio and user_id = auth.uid() and deleted_at is null;
  if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  if coalesce(p_pay_mode, 'xendit') not in ('xendit', 'pack', 'credit') then
    return jsonb_build_object('ok', false, 'reason', 'bad_pay_mode'); end if;
  return private_book_run(v_member, p_type_id, p_instructor_id, p_starts_at,
                          coalesce(p_companions, '[]'::jsonb), coalesce(p_pay_mode, 'xendit'),
                          null, null, p_code);
end $$;
revoke execute on function private_book(uuid, uuid, timestamptz, jsonb, text, text) from public, anon;
grant execute on function private_book(uuid, uuid, timestamptz, jsonb, text, text) to authenticated, service_role;

-- ---- sales_totals: re-issued (20260833670000_step12_promotions_return_credit.sql:1023), + the Discount codes line ----
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz; v_resv_count int; v_resv_total bigint;
  v_ref_count int; v_ref_total bigint;
  v_gift_count int; v_gift_total bigint; v_redeem_count int; v_redeem_total bigint;
  v_priv_count int; v_priv_total bigint; v_priv_coach bigint;
  v_disc_count int; v_disc_total bigint;
  v_code_count int; v_code_total bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_resv_count, v_resv_total
    from payments p
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(pr.amount_cents), 0)::bigint
    into v_ref_count, v_ref_total
    from payment_refunds pr
   where pr.studio_id = p_studio_id and pr.status = 'succeeded'
     and coalesce(pr.settled_at, pr.created_at) >= v_f0
     and coalesce(pr.settled_at, pr.created_at) <  v_t1;

  -- Decision 110: gift cards sold (cash received), and gift credit redeemed
  -- (source credit, excluded from revenue — shown so the two can be reconciled).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_gift_count, v_gift_total
    from payments p
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(p.amount_cents), 0)::bigint
    into v_redeem_count, v_redeem_total
    from payments p
   where p.studio_id = p_studio_id and coalesce(p.source, '') = 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 116: private sessions sold in the period (cash/card, not a credit
  -- rebook), the coach pay read from each session's pay record, and the VAT
  -- split (12 percent inclusive, the Decision 88c invoice arithmetic).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint,
         coalesce(sum(coalesce((select ipr.amount_cents from instructor_pay_records ipr
                                 where ipr.occurrence_id = b.occurrence_id and ipr.type = 'class'
                                 limit 1), 0)), 0)::bigint
    into v_priv_count, v_priv_total, v_priv_coach
    from payments p
    join bookings b on b.id = p.booking_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 117: discounts given on sales in the period.
  select count(*), coalesce(sum(p.discount_cents), 0)::bigint
    into v_disc_count, v_disc_total
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id and p.promotion_id is not null
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  -- Decision 120: discount codes used on sales in the period.
  select count(*), coalesce(sum(p.discount_cents), 0)::bigint
    into v_code_count, v_code_total
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id and p.discount_code_use_id is not null
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  return jsonb_build_object(
    'codes', jsonb_build_object('count', v_code_count, 'total_cents', v_code_total),
    'discounts', jsonb_build_object('count', v_disc_count, 'total_cents', v_disc_total),
    'private', jsonb_build_object('count', v_priv_count, 'total_cents', v_priv_total,
      'after_vat_cents', round(v_priv_total / 1.12)::bigint,
      'vat_cents', v_priv_total - round(v_priv_total / 1.12)::bigint,
      'coach_pay_cents', v_priv_coach,
      'studio_keeps_cents', v_priv_total - v_priv_coach),
    'refunds', jsonb_build_object('count', v_ref_count, 'total_cents', v_ref_total),
    'reservation_fees', jsonb_build_object('count', v_resv_count, 'total_cents', v_resv_total),
    'gift_sold', jsonb_build_object('count', v_gift_count, 'total_cents', v_gift_total),
    'gift_redeemed', jsonb_build_object('count', v_redeem_count, 'total_cents', v_redeem_total),
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;
revoke execute on function sales_totals(uuid, date, date, uuid, text) from public, anon;
grant  execute on function sales_totals(uuid, date, date, uuid, text) to authenticated, service_role;

-- ---- The public surface is unchanged: exactly fifteen anon functions --------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
end $$;
