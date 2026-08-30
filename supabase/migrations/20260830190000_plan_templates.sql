-- =============================================================================
-- MIGRATION 008 — plan_templates, and a guard on deleting a plan in use
--
-- Same shape as challenge_templates: studio_id null means a system template,
-- shipped with the product and readable by every studio. A studio may also
-- save its own, which is why the column is nullable rather than absent.
--
-- The six system templates live here rather than in supabase/seed.sql because
-- seed.sql is local development data — it says so at the top — and these are
-- product data that every environment needs. Fixed ids, inserted idempotently,
-- so re-running is a no-op and a later migration can correct one in place.
--
-- Templates carry no price. See the comment on price_cents below: a suggested
-- number is only meaningful next to a currency, and the currency belongs to
-- the studio, not to the template.
-- =============================================================================

create table plan_templates (
  id                       uuid primary key default gen_random_uuid(),
  studio_id                uuid references studios on delete cascade,  -- null = system
  name                     text not null,
  description              text,
  type                     plan_type not null,
  -- Deliberately nullable and null on every system template. 280000 is a fair
  -- monthly unlimited in CZK and an absurd one in EUR or USD, and money that
  -- arrives pre-filled is money that ships unread. The structure is what
  -- transfers between studios; the price is not.
  price_cents              int check (price_cents is null or price_cents >= 0),
  billing_interval         billing_interval,
  billing_interval_count   int not null default 1,
  credits                  int,
  credits_per_period       int,
  validity_days            int,
  signup_fee_cents         int not null default 0,
  commitment_months        int not null default 0,
  cancellation_notice_days int not null default 0,
  freeze_allowed           boolean not null default true,
  max_freeze_days          int,
  booking_window_days      int,
  max_bookings_per_day     int,
  restrictions             jsonb not null default '{}',
  visibility               text not null default 'public',
  sort_order               int not null default 0,
  created_at               timestamptz not null default now()
);
create index on plan_templates (studio_id, sort_order);

comment on table plan_templates is
  'Starting points for membership_plans. studio_id null is a system template '
  'shipped with the product; a non-null studio_id is one a studio saved for '
  'itself. Nothing here is ever charged — a plan is created by copying these '
  'fields onto membership_plans, where the price is set.';

alter table plan_templates enable row level security;

-- Plans are money, so templates follow the same line as the plans themselves:
-- Permissions §9 gives "Create / edit plans" to Owner and Manager only, and
-- templates exist only to create plans. Instructors and front desk get nothing
-- here, and members never see this table at all.
create policy plan_templates_manager_read on plan_templates for select
  using (
    case
      when studio_id is null then exists (
        select 1 from studio_staff s
         where s.user_id = auth.uid() and s.status = 'active'
           and s.role in ('owner','manager'))
      else is_manager_up(studio_id)
    end
  );

-- A studio may write its own templates. Nobody edits the system ones.
create policy plan_templates_manager_write on plan_templates for all
  using (studio_id is not null and is_manager_up(studio_id))
  with check (studio_id is not null and is_manager_up(studio_id));

grant select, insert, update, delete on plan_templates to authenticated, service_role;

-- =============================================================================
-- The six a Pilates or yoga studio actually sells.
--
-- Every structural field is filled so the form arrives complete; only the
-- price is left for the owner. Descriptions say what the shape is for, because
-- picking between "10-class pack" and "5-class pack" is a pricing decision,
-- not a data-entry one.
-- =============================================================================

insert into plan_templates
  (id, studio_id, name, description, type, billing_interval, billing_interval_count,
   credits, credits_per_period, validity_days, commitment_months,
   cancellation_notice_days, freeze_allowed, max_freeze_days, visibility, sort_order)
values
  ('00000000-0000-0000-0001-000000000001', null,
   'Unlimited Monthly',
   'Every class, billed monthly. The anchor plan most studios build around — '
   'highest price, best value for anyone coming twice a week or more.',
   'recurring', 'month', 1, null, null, null, 0, 0, true, 60, 'public', 1),

  ('00000000-0000-0000-0001-000000000002', null,
   '8 Classes Monthly',
   'Eight classes a month, billed monthly. Unused classes do not roll over '
   '(Decision 3). Suits the twice-a-week member who will not pay for unlimited.',
   'recurring', 'month', 1, null, 8, null, 0, 0, true, 60, 'public', 2),

  ('00000000-0000-0000-0001-000000000003', null,
   '10-Class Pack',
   'Ten classes, six months to use them. No commitment, no billing — the '
   'flexible option for irregular attenders and the usual step up from a pack '
   'of five.',
   'class_pack', null, 1, 10, null, 180, 0, 0, false, null, 'public', 3),

  ('00000000-0000-0000-0001-000000000004', null,
   '5-Class Pack',
   'Five classes, three months to use them. The smallest commitment worth '
   'selling; often what a member buys straight after an intro offer.',
   'class_pack', null, 1, 5, null, 90, 0, 0, false, null, 'public', 4),

  ('00000000-0000-0000-0001-000000000005', null,
   'Single Drop-in',
   'One class, valid a month. Visitors, and anyone who wants to try a class '
   'before buying anything larger.',
   'drop_in', null, 1, 1, null, 30, 0, 0, false, null, 'public', 5),

  ('00000000-0000-0000-0001-000000000006', null,
   'Intro Offer',
   'Three classes in two weeks, for new members only. Deliberately short: the '
   'point is to get someone in three times quickly, while the decision is warm. '
   'Trials are a plan type, not a flag — this converts or expires (§7.1).',
   'trial', null, 1, 3, null, 14, 0, 0, false, null, 'public', 6)
on conflict (id) do nothing;

-- =============================================================================
-- A plan with members on it cannot be deleted.
--
-- CLAUDE.md: deletes are soft. memberships.plan_id is `references
-- membership_plans` with no ON DELETE, so Postgres would already refuse — but
-- it refuses with a foreign key violation naming a constraint, which tells the
-- owner nothing about what to do instead. This says it, and it says it for
-- every path, not just the one screen that happens to check first.
-- =============================================================================

create function guard_plan_delete() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  select count(*) into n
    from memberships
   where plan_id = old.id
     and status not in ('cancelled','expired');

  if n > 0 then
    raise exception
      'plan "%" has % membership(s) on it and cannot be deleted', old.name, n
      using errcode = 'PT409',
            hint = 'Set status = ''archived'' instead. Existing members keep '
                   'the plan and the price they bought at; it stops being '
                   'sellable.';
  end if;
  return old;
end $$;

create trigger membership_plans_no_delete_in_use
  before delete on membership_plans
  for each row execute function guard_plan_delete();

revoke execute on function guard_plan_delete() from public;

comment on column membership_plans.status is
  'active | archived. Archiving is how a plan is retired: memberships.price_cents '
  'is snapshotted at purchase (§7.1), so existing members are unaffected by '
  'anything done to the plan afterwards, including archiving it.';
