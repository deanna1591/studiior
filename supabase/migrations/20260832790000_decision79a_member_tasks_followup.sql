-- Decision 79a — member_tasks gains the 'follow_up' kind (snooze on a task-less
-- section), a due_at for snoozing, and contact_id linking it to the contact that
-- closed it. The kind CHECK is altered in its own migration (the enum/CHECK rule).
--
-- A CHECK is not an enum, so adding a value needs no separate transaction the way
-- ALTER TYPE ... ADD VALUE does; it is in its own file to keep the schema change
-- auditable beside the columns it enables.

alter table member_tasks drop constraint if exists member_tasks_kind_check;
alter table member_tasks add constraint member_tasks_kind_check
  check (kind in ('unconverted_day7','at_risk','drifting_fyi','follow_up'));

alter table member_tasks add column if not exists due_at     timestamptz;
alter table member_tasks add column if not exists contact_id uuid references member_contacts on delete set null;

-- A snoozed task is hidden until its due date; the board filters on this.
create index if not exists member_tasks_due on member_tasks (studio_id, due_at)
  where status = 'open' and due_at is not null;
