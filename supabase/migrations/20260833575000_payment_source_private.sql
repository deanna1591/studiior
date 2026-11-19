-- Decision 116 — the payment_source value 'private', carried alone.
-- A new enum value cannot be USED in the transaction that adds it (the 036 / 247
-- trap), so it ships in its own migration ahead of the private-sessions build.
-- A private session seat is paid in full or from a 1:1 pack credit; it is neither
-- a comp, a drop-in, nor a group seat, so it has its own source. Idempotent.
do $$ begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                 where t.typname = 'payment_source' and e.enumlabel = 'private') then
    alter type payment_source add value 'private';
  end if;
end $$;
