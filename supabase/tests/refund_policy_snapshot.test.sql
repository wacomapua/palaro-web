-- Owner decision 1 / contract C3 (P3): a booking is refunded under the policy
-- in force when it was made. book_venue_slot stores
-- coalesce(slot.refund_policy, venue.default_refund_policy) on the booking;
-- cancel_venue_booking resolves
-- coalesce(booking.refund_policy_snapshot, slot.refund_policy, venue.default_refund_policy).
begin;
select plan(20);

select has_column('public', 'venue_bookings', 'refund_policy_snapshot', 'venue_bookings has refund_policy_snapshot');
select col_type_is('public', 'venue_bookings', 'refund_policy_snapshot', 'jsonb', 'refund_policy_snapshot is jsonb');

\set stock '{"tiers":[{"hours_before":48,"refund_pct":100},{"hours_before":24,"refund_pct":50},{"hours_before":0,"refund_pct":0}]}'
\set strict72 '{"tiers":[{"hours_before":72,"refund_pct":100},{"hours_before":0,"refund_pct":0}]}'
\set anyfull '{"tiers":[{"hours_before":0,"refund_pct":100}]}'
\set nothing '{"tiers":[{"hours_before":0,"refund_pct":0}]}'

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset
update public.venues set default_refund_policy = :'stock' where id = :'venue';
select tests.create_court(:'venue', 'Court A') as court_a \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select now() + interval '30 hours' as t30 \gset

-- 1. book_venue_slot writes the effective policy.
select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz, :'t30'::timestamptz + interval '1 hour') as s_default \gset
select booking_id as b_default from public.book_venue_slot(:'s_default', :'player', null) \gset
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_default'), :'stock'::jsonb,
  'exclusive slot without an override: the venue default is snapshotted');

select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz + interval '2 hours', :'t30'::timestamptz + interval '3 hours') as s_override \gset
update public.venue_slots set refund_policy = :'strict72' where id = :'s_override';
select booking_id as b_override from public.book_venue_slot(:'s_override', :'player', null) \gset
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_override'), :'strict72'::jsonb,
  'exclusive slot with an override: the override is snapshotted');

select tests.create_slot(:'venue', :'course', :'t30'::timestamptz, :'t30'::timestamptz + interval '10 minutes', 50000, 4) as s_tee \gset
select booking_id as b_tee from public.book_venue_slot(:'s_tee', :'player', null, 2) \gset
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_tee'), :'stock'::jsonb,
  'shared tee time without an override: the venue default is snapshotted');

update public.venue_slots set refund_policy = :'anyfull' where id = :'s_tee';
select booking_id as b_tee2 from public.book_venue_slot(:'s_tee', :'player', null, 1) \gset
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_tee2'), :'anyfull'::jsonb,
  'shared tee time with an override: the override is snapshotted');
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_tee'), :'stock'::jsonb,
  'an earlier golfer on that tee time keeps the policy they booked under');

-- 2. Editing the policies afterwards changes neither the snapshot nor the refund.
update public.venues set default_refund_policy = :'anyfull' where id = :'venue';
update public.venue_slots set refund_policy = :'nothing' where id = :'s_default';
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_default'), :'stock'::jsonb,
  'owner edits to the venue default and the slot override leave the snapshot alone');

select tests.claims(:'player');
select * from public.cancel_venue_booking(:'b_default', 'changed plans') \gset c_default_
select is(:c_default_refund_amount_cents, 50000,
  'cancel_venue_booking refunds under the snapshot (stock, 30h: 50%), not the new default (100%) or override (0%)');

select * from public.cancel_venue_booking(:'b_override', null) \gset c_override_
select is(:c_override_refund_amount_cents, 0,
  'cancel_venue_booking: snapshot of a strict 72h override still gives 0% at 32h after the default became full refund');

-- 3. Bookings without a snapshot (made before it existed) fall back as before.
select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz + interval '4 hours', :'t30'::timestamptz + interval '5 hours', 100000, null, 'booked') as s_legacy_slot \gset
update public.venue_slots set refund_policy = :'nothing' where id = :'s_legacy_slot';
select tests.create_booking(:'s_legacy_slot', :'player', 'paid') as b_legacy_slot \gset
select * from public.cancel_venue_booking(:'b_legacy_slot', null) \gset c_legacy_slot_
select is(:c_legacy_slot_refund_amount_cents, 0, 'no snapshot: the slot override applies');

select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz + interval '6 hours', :'t30'::timestamptz + interval '7 hours', 100000, null, 'booked') as s_legacy_venue \gset
select tests.create_booking(:'s_legacy_venue', :'player', 'paid') as b_legacy_venue \gset
select * from public.cancel_venue_booking(:'b_legacy_venue', null) \gset c_legacy_venue_
select is(:c_legacy_venue_refund_amount_cents, 100000, 'no snapshot and no override: the venue default applies');

-- 4. The backfill in 20260531000002, verbatim. Live bookings get their
--    current effective policy; cancelled ones and existing snapshots are left.
update public.venues set default_refund_policy = :'stock' where id = :'venue';
select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz + interval '8 hours', :'t30'::timestamptz + interval '9 hours', 100000, null, 'booked') as s_bf1 \gset
select tests.create_slot(:'venue', :'court_a', :'t30'::timestamptz + interval '10 hours', :'t30'::timestamptz + interval '11 hours', 100000, null, 'booked') as s_bf2 \gset
update public.venue_slots set refund_policy = :'strict72' where id = :'s_bf2';
select tests.create_slot(:'venue', :'course', :'t30'::timestamptz + interval '12 hours', :'t30'::timestamptz + interval '12 hours 10 minutes', 50000, 4) as s_bf3 \gset
select tests.create_booking(:'s_bf1', :'player', 'paid') as bf_paid \gset
select tests.create_booking(:'s_bf2', :'player', 'pending_payment') as bf_pending \gset
select tests.create_booking(:'s_bf3', :'player', 'completed') as bf_completed \gset
select tests.create_booking(:'s_bf3', :'player', 'refunded') as bf_refunded \gset
select tests.create_booking(:'s_bf3', :'player', 'cancelled') as bf_cancelled \gset
select tests.create_booking(:'s_bf3', :'player', 'paid') as bf_kept \gset
update public.venue_bookings set refund_policy_snapshot = :'nothing' where id = :'bf_kept';

update public.venue_bookings b
   set refund_policy_snapshot = coalesce(s.refund_policy, v.default_refund_policy)
  from public.venue_slots s, public.venues v
 where s.id = b.slot_id
   and v.id = b.venue_id
   and b.status <> 'cancelled'
   and b.refund_policy_snapshot is null;

select results_eq(
  format($q$
    select id, refund_policy_snapshot from public.venue_bookings
     where id in (%L, %L, %L, %L) order by id
  $q$, :'bf_paid', :'bf_pending', :'bf_completed', :'bf_refunded'),
  format($q$
    select * from (values
      (%L::uuid, %L::jsonb), (%L::uuid, %L::jsonb), (%L::uuid, %L::jsonb), (%L::uuid, %L::jsonb)
    ) v order by 1
  $q$, :'bf_paid', :'stock', :'bf_pending', :'strict72', :'bf_completed', :'stock', :'bf_refunded', :'stock'),
  'backfill: paid, pending, completed and refunded bookings get the policy in force now'
);
select is((select refund_policy_snapshot from public.venue_bookings where id = :'bf_cancelled'), null,
  'backfill: cancelled bookings are left without a snapshot');
select is((select refund_policy_snapshot from public.venue_bookings where id = :'bf_kept'), :'nothing'::jsonb,
  'backfill: an existing snapshot is never overwritten');

-- 5. Clients cannot rewrite their own terms.
set local role authenticated;
select tests.claims(:'player');
update public.venue_bookings set refund_policy_snapshot = :'anyfull' where id = :'bf_paid';
select tests.claims(:'owner');
update public.venue_bookings set refund_policy_snapshot = :'anyfull' where id = :'bf_paid';
reset role;
select is((select refund_policy_snapshot from public.venue_bookings where id = :'bf_paid'), :'stock'::jsonb,
  'neither the captain nor the venue owner can rewrite a snapshot');

-- 6. The snapshot is what the captain was shown: it survives the slot override
--    being removed too.
update public.venue_slots set refund_policy = null where id = :'s_override';
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_override'), :'strict72'::jsonb,
  'removing the slot override leaves the snapshot');

-- 7. book_venue_slot keeps its signature and security.
select has_function('public', 'book_venue_slot',
  array['uuid', 'uuid', 'uuid', 'integer', 'integer', 'numeric'], 'book_venue_slot keeps its signature');
select is_definer('public', 'book_venue_slot',
  array['uuid', 'uuid', 'uuid', 'integer', 'integer', 'numeric'], 'book_venue_slot stays security definer');
select is_definer('public', 'cancel_venue_booking', array['uuid', 'text'], 'cancel_venue_booking stays security definer');

select * from finish();
rollback;
