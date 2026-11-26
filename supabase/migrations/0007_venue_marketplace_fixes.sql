-- =============================================================================
-- Venue marketplace — review-fix patches
-- =============================================================================
-- Two CRITICAL fixes from the PR #6 code review:
--   1. Fix the dead-code race check in complete_venue_booking. The original
--      `_slot.id <> _booking.slot_id` was always false (we selected the slot
--      by exactly that id), so a late webhook would silently overwrite a
--      re-booked slot, letting two captains both end up "paid" on the same
--      physical slot. The correct check is whether ANOTHER active booking
--      already references this slot — if so, our hold lost the race and
--      we cancel ourselves; the caller refunds via PayMongo.
--   2. Revoke execute on complete_venue_booking from anon/authenticated. The
--      RPC marks bookings paid + creates events; clients should never call it
--      directly. Without the revoke, an authed captain could call it with
--      their own pending intent_id and self-mark "paid" without ever paying.
--      Service role retained — webhook is the only legitimate caller.
-- =============================================================================

create or replace function public.complete_venue_booking(
  _intent_id text
) returns table (
  booking_id uuid,
  event_id uuid,
  status venue_booking_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _booking record;
  _slot record;
  _venue record;
  _court record;
  _event_id uuid;
  _slot_count int;
  _slot_fee_cents int;
  _event_title text;
  _other_booking uuid;
begin
  select b.* into _booking
    from public.venue_bookings b
   where b.paymongo_intent_id = _intent_id
   for update;

  if not found then
    raise exception 'No booking for intent %', _intent_id using errcode = 'no_data_found';
  end if;

  -- Idempotency.
  if _booking.status in ('paid', 'completed', 'cancelled', 'refunded') then
    return query select _booking.id, _booking.event_id, _booking.status;
    return;
  end if;

  select s.* into _slot from public.venue_slots s where s.id = _booking.slot_id for update;
  select v.* into _venue from public.venues v where v.id = _booking.venue_id;
  select c.* into _court from public.venue_courts c where c.id = _slot.court_id;

  -- Race detection. The original guard `_slot.id <> _booking.slot_id` was
  -- a tautology — we just selected `_slot` by exactly that id. The real
  -- race is: our hold expired, the cron flipped the slot back to
  -- 'available', another captain called book_venue_slot and PAID for the
  -- slot, our late webhook arrives. We only cancel ourselves when another
  -- booking on this slot is decisively a winner — i.e. already 'paid' or
  -- 'completed'. We deliberately do NOT treat 'pending_payment' as a
  -- competitor: stale pending_payment rows from abandoned PayMongo intents
  -- linger in the table forever (the cron releases held slots but never
  -- cancels their bookings), and counting them would cause legitimate
  -- payments to be cancelled simply because some earlier captain abandoned
  -- a tab.
  --
  -- The slot's `for update` lock above serialises any concurrent
  -- complete_venue_booking on the same slot, so this unlocked SELECT
  -- against venue_bookings sees a consistent view.
  select b.id into _other_booking
    from public.venue_bookings b
   where b.slot_id = _booking.slot_id
     and b.id <> _booking.id
     and b.status in ('paid', 'completed')
   limit 1;

  if _other_booking is not null then
    update public.venue_bookings
       set status = 'cancelled',
           refund_reason = 'Slot taken before payment confirmed',
           updated_at = now()
     where id = _booking.id;
    return query select _booking.id, _booking.event_id, 'cancelled'::venue_booking_status;
    return;
  end if;

  update public.venue_slots
     set status = 'booked', held_until = null
   where id = _slot.id;

  update public.venue_bookings
     set status = 'paid', updated_at = now()
   where id = _booking.id;

  insert into public.transactions (
    team_id, user_id, type, amount_cents, currency,
    platform_fee_cents, gateway, gateway_ref, status, metadata
  ) values (
    _booking.team_id, _booking.captain_user_id, 'venue_booking',
    _booking.total_cents, _venue.currency,
    _booking.platform_fee_cents, 'paymongo', _intent_id, 'succeeded',
    jsonb_build_object(
      'booking_id', _booking.id,
      'slot_id', _slot.id,
      'venue_id', _venue.id,
      'court_id', _court.id
    )
  );

  if _booking.team_id is not null then
    _slot_count := greatest(
      coalesce(_court.capacity / 2, case _venue.sport
        when 'football'   then 11
        when 'basketball' then 5
        when 'tennis'     then 2
        when 'pickleball' then 2
        when 'volleyball' then 6
      end),
      1
    );
    _slot_fee_cents := ceil(_booking.total_cents::numeric / _slot_count)::int;
    _event_title := 'Match at ' || _venue.name;

    insert into public.events (
      team_id, title, type, status, location,
      starts_at, ends_at, slot_count, reserve_count,
      slot_fee_cents, currency, flake_fee_cents,
      created_by, venue_booking_id
    ) values (
      _booking.team_id, _event_title, 'match', 'draft',
      _venue.name || ' · ' || _venue.address,
      _slot.starts_at, _slot.ends_at, _slot_count, 3,
      _slot_fee_cents, _venue.currency, 0,
      _booking.captain_user_id, _booking.id
    )
    returning id into _event_id;

    update public.venue_bookings
       set event_id = _event_id, updated_at = now()
     where id = _booking.id;
  end if;

  return query select _booking.id, _event_id, 'paid'::venue_booking_status;
end;
$$;

-- Lock the RPC down to service_role only. The webhook is the legitimate
-- caller; clients calling directly is the security hole we're closing.
revoke execute on function public.complete_venue_booking(text) from public;
revoke execute on function public.complete_venue_booking(text) from anon;
revoke execute on function public.complete_venue_booking(text) from authenticated;
grant execute on function public.complete_venue_booking(text) to service_role;
