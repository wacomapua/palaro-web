-- =============================================================================
-- Venue marketplace — enum extensions (must run in their own migration)
-- =============================================================================
-- Postgres requires `alter type ... add value` to run outside any transaction
-- that has already executed CRUD against the same enum's domain. Supabase
-- runs each migration file in its own transaction, so we isolate the enum
-- extensions here and put the new tables/indexes/functions in 0005.
-- =============================================================================

alter type txn_type     add value if not exists 'venue_booking';
alter type txn_type     add value if not exists 'venue_payout';
alter type txn_type     add value if not exists 'venue_refund';
alter type event_status add value if not exists 'draft';
