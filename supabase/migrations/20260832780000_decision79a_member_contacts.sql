-- Decision 79a — member_contacts: the outreach log behind the retention page.
-- One row per contact (email / viber / call / in person), its situation, the
-- staff member, and the outcome the sweep fills in 14 days later. This is the
-- authoritative record for every section — drifting, expiring and lapsed carry
-- no member_tasks row, so the contact row is the record.
--
-- creates: member_contacts (table)
-- Authorised by Deanna, 21 Oct 2026.

create table member_contacts (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  situation     text not null check (situation in
                  ('unconverted','at_risk','drifting','expiring','lapsed','other')),
  method        text not null check (method in ('email','viber','call','in_person')),
  subject       text,
  staff_id      uuid references profiles,
  contacted_at  timestamptz not null default now(),
  -- Filled by the sweep 14 days on: did the member come back, and after how long.
  outcome       text check (outcome in ('booked','visited','bought','renewed','none')),
  outcome_at    timestamptz,
  outcome_days  int
);
create index member_contacts_recent on member_contacts (studio_id, member_id, contacted_at desc);
-- The sweep scans by studio for rows still waiting on an outcome.
create index member_contacts_pending on member_contacts (studio_id, contacted_at)
  where outcome is null;

alter table member_contacts enable row level security;

-- Manager-up reads its studio's contacts; front desk reads only when the studio
-- routes retention to them. Writes are the SECURITY DEFINER RPCs + the service
-- sweep, never a direct client write, so there is no insert/update/delete policy.
create policy member_contacts_read on member_contacts for select using (
  coalesce(is_manager_up(studio_id), false)
  or (coalesce(is_desk_up(studio_id), false)
      and coalesce((select retention_tasks_to from studio_settings
                     where studio_id = member_contacts.studio_id), 'owner_manager') = 'front_desk')
);

grant select on member_contacts to authenticated;
grant all on member_contacts to service_role;
