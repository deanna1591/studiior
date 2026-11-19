-- Decision 116 amendment (a): a group class replaced by a private session is
-- cancelled with its own cause, so pay and every screen can say so. The value is
-- carried alone: a new enum value cannot be used in the transaction that adds it.
alter type cancellation_cause add value if not exists 'replaced_by_private';
