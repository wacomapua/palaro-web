-- What 20260531000001 itself did to closures that already existed. The data
-- was seeded by supabase/tests/premigrate/20260531000001_scheduling_closures_fixes.sql
-- before the migration ran; nothing here calls apply_venue_closure.
begin;
select plan(30);

create temp view pm_booking as
  select right(id::text, 3) as k, status::text as status, refund_amount_cents, refund_reason
    from public.venue_bookings where id::text like '00000000-5eed-%';
create temp view pm_slot as
  select right(id::text, 3) as k, status::text as status
    from public.venue_slots where id::text like '00000000-5eed-%';
create temp view pm_refund as
  select right(booking_id::text, 3) as k, amount_cents, reason, status
    from public.venue_refunds where booking_id::text like '00000000-5eed-%';

-- CL1, a closure on North: its child Q1 and parent Pitch are covered.
select is((select status from pm_booking where k = 'b01'), 'cancelled', 'CL1: paid booking on the child court is cancelled');
select results_eq($$select amount_cents, reason, status from pm_refund where k = 'b01'$$,
  $$values (120000, 'venue_closure', 'pending')$$, 'CL1: exactly one full venue_closure refund queued for it');
select is((select refund_amount_cents from pm_booking where k = 'b01'), 120000, 'CL1: the booking records the full refund');
select is((select refund_reason from pm_booking where k = 'b01'), 'Venue closure: Resurfacing', 'CL1: with the closure''s reason');
select is((select status::text from public.events where id = '00000000-5eed-0000-0000-00000000f002'), 'cancelled', 'CL1: its match event is cancelled');
select is((select status from pm_slot where k = 'e01'), 'closed', 'CL1: the booked child slot is closed');
select is((select status from pm_booking where k = 'b02'), 'cancelled', 'CL1: pending booking on the held slot is cancelled');
select is((select count(*)::int from pm_refund where k = 'b02'), 0, 'CL1: with no refund');
select is((select status from pm_slot where k = 'e02'), 'closed', 'CL1: the held slot is closed');
select is((select status from pm_slot where k = 'e04'), 'closed', 'CL1: the open parent slot is closed');
select is((select status from pm_booking where k = 'b03'), 'paid', 'CL1: the sibling court''s paid booking is untouched');
select is((select status from pm_slot where k = 'e03'), 'booked', 'CL1: and its slot stays booked');

-- CL2, a closure on the parent Pitch: every court under it is covered.
select is((select status from pm_booking where k = 'b05'), 'cancelled', 'CL2: zero total paid booking under the parent closure is cancelled');
select is((select count(*)::int from pm_refund where k = 'b05'), 0, 'CL2: with no refund row (nothing to refund)');
select is((select status from pm_slot where k = 'e05'), 'closed', 'CL2: its slot is closed');
select is((select status from pm_booking where k = 'b06'), 'cancelled', 'CL2: an already cancelled booking stays cancelled');
select is((select count(*)::int from pm_refund where k = 'b06'), 0, 'CL2: and gets no refund');
select is((select status from pm_slot where k = 'e06'), 'closed', 'CL2: the grandchild slot is closed');

-- CL3, whole venue: the shared tee time and an unrelated court.
select results_eq($$select k, amount_cents, reason from pm_refund where k in ('b7a', 'b7b') order by k$$,
  $$values ('b7a', 100000, 'venue_closure'), ('b7b', 50000, 'venue_closure')$$,
  'CL3: each paid golfer gets exactly one full refund');
select is((select array_agg(status order by k) from pm_booking where k in ('b7a', 'b7b', 'b7c')), array['cancelled', 'cancelled', 'cancelled'],
  'CL3: every golfer on the tee time is cancelled');
select is((select count(*)::int from pm_refund where k = 'b7c'), 0, 'CL3: the pending golfer gets no refund');
select is((select status from pm_slot where k = 'e07'), 'closed', 'CL3: the part booked tee time is closed');
select is((select status from pm_slot where k = 'e08'), 'closed', 'CL3: an open slot on another court is closed');

-- CL4 already ended: nothing under it changes.
select is((select status from pm_booking where k = 'b09'), 'paid', 'CL4: a played game under an ended closure keeps its payment');
select is((select status from pm_slot where k = 'e09'), 'booked', 'CL4: and its slot');

-- Outside every active closure.
select is((select status from pm_booking where k = 'b10'), 'paid', 'a separate court at a closed court''s time is untouched');
select is((select status from pm_slot where k = 'e10'), 'booked', 'and its slot stays booked');
select is((select status from pm_booking where k = 'b11'), 'paid', 'another venue''s booking is untouched');
select is((select status from pm_slot where k = 'e11'), 'booked', 'and its slot stays booked');

select is((select count(*)::int from pm_refund), 3, 'exactly three refunds in total for the seeded data (b01, b7a, b7b)');

select * from finish();
rollback;
