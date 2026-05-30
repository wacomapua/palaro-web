// Hand-written shape of the Postgres schema.
// Mirrors team-manager/src/types/db.ts; both apps share the same Supabase project.
// Regenerate with `supabase gen types typescript` once the project is provisioned.

export type Json = string | number | boolean | null | { [k: string]: Json } | Json[];

export type EventType = 'match' | 'practice' | 'social' | 'meetup';
export type EventStatus = 'scheduled' | 'cancelled' | 'completed' | 'draft';
export type TxnType =
  | 'slot'
  | 'flake'
  | 'club_dues'
  | 'captain_subscription'
  | 'marketplace'
  | 'venue_booking'
  | 'venue_payout'
  | 'venue_refund';

export type VenueSport =
  | 'football'
  | 'basketball'
  | 'tennis'
  | 'pickleball'
  | 'volleyball'
  | 'golf'
  | 'badminton'
  | 'swimming'
  | 'squash';
export type VenueStatus = 'pending_review' | 'active' | 'suspended';
export type VenueSlotStatus = 'available' | 'held' | 'booked' | 'cancelled' | 'closed';
// How a slot is consumed:
//  - 'exclusive': one booking owns the whole slot (court sports)
//  - 'shared':    multiple bookings share it up to max_players (golf tee times)
export type BookingMode = 'exclusive' | 'shared';
// How a slot is priced:
//  - 'per_slot':   price_cents is the total for the slot
//  - 'per_player': price_per_player_cents is charged per player in the party
export type PricingMode = 'per_slot' | 'per_player';
export type VenueBookingStatus =
  | 'pending_payment'
  | 'paid'
  | 'cancelled'
  | 'refunded'
  | 'completed';
export type VenuePayoutStatus = 'pending' | 'paid' | 'failed';

export type Profile = {
  id: string;
  phone: string | null;
  email: string | null;
  display_name: string | null;
  avatar_url: string | null;
  created_at: string;
}

export type RefundTier = {
  hours_before: number;
  refund_pct: number;
}

export type RefundPolicy = {
  tiers: RefundTier[];
}

export type PayoutMethod = {
  method: 'gcash' | 'bank';
  gcash_number?: string;
  bank_name?: string;
  account_no?: string;
  account_name?: string;
}

export type Venue = {
  id: string;
  slug: string;
  name: string;
  // The venue's primary/default sport. The full set a venue offers lives in
  // venue_sports (a venue can run many sports across its courts).
  sport: VenueSport;
  address: string;
  city: string | null;
  lat: number | null;
  lng: number | null;
  phone: string | null;
  description: string | null;
  cover_image_url: string | null;
  owner_id: string;
  status: VenueStatus;
  currency: string;
  // IANA timezone the venue operates in (e.g. 'Asia/Manila'). All slot day/time
  // math is anchored to this, not the server or browser timezone.
  timezone: string;
  payout_method: PayoutMethod | null;
  default_refund_policy: RefundPolicy;
  created_at: string;
  updated_at: string;
}

export type VenueSportOffering = {
  id: string;
  venue_id: string;
  sport: VenueSport;
  active: boolean;
  created_at: string;
}

export type VenueCourt = {
  id: string;
  venue_id: string;
  parent_court_id: string | null;
  // Which sport this court belongs to (a multi-sport venue has courts spanning
  // several sports). Backfilled from the venue's primary sport on migration.
  sport: VenueSport;
  name: string;
  kind: string | null;
  sort_order: number;
  capacity: number | null;
  metadata: Json | null;
  active: boolean;
  created_at: string;
}

export type VenueSlot = {
  id: string;
  venue_id: string;
  court_id: string;
  starts_at: string;
  ends_at: string;
  price_cents: number;
  // Per-player price, used when pricing_mode = 'per_player' (e.g. golf tee times).
  price_per_player_cents: number | null;
  currency: string;
  status: VenueSlotStatus;
  // 'exclusive' (court sports) or 'shared' (golf tee times, up to max_players).
  booking_mode: BookingMode;
  pricing_mode: PricingMode;
  // For shared slots: max players across all bookings (e.g. 4 for a foursome).
  // null for exclusive slots (capacity is the court's capacity).
  max_players: number | null;
  refund_policy: RefundPolicy | null;
  held_until: string | null;
  generated_from_template_id: string | null;
  created_by: string | null;
  created_at: string;
}

export type VenueBooking = {
  id: string;
  slot_id: string;
  venue_id: string;
  team_id: string | null;
  captain_user_id: string;
  event_id: string | null;
  // Number of players this booking brings. For shared (golf) slots the sum of
  // party_size across active bookings must not exceed slot.max_players.
  party_size: number;
  total_cents: number;
  platform_fee_cents: number;
  payout_cents: number;
  status: VenueBookingStatus;
  paymongo_intent_id: string | null;
  refund_amount_cents: number;
  refund_reason: string | null;
  refunded_at: string | null;
  payout_id: string | null;
  metadata: Json | null;
  created_at: string;
  updated_at: string;
}

export type VenueSlotTemplate = {
  id: string;
  venue_id: string;
  court_id: string;
  day_of_week: number; // 0 = Sunday … 6 = Saturday
  start_time: string; // 'HH:MM:SS'
  end_time: string;
  slot_minutes: number;
  price_cents: number;
  refund_policy: RefundPolicy | null;
  active: boolean;
  paused_until: string | null;
  created_at: string;
}

export type VenueClosure = {
  id: string;
  venue_id: string;
  court_id: string | null; // null = whole venue
  starts_at: string;
  ends_at: string;
  reason: string | null;
  created_at: string;
}

export type VenuePayout = {
  id: string;
  venue_id: string;
  period_start: string;
  period_end: string;
  gross_cents: number;
  fees_cents: number;
  net_cents: number;
  currency: string;
  status: VenuePayoutStatus;
  payout_method_snapshot: PayoutMethod | null;
  gateway_ref: string | null;
  paid_at: string | null;
  created_at: string;
}

type TableShape<R> = {
  Row: R & Record<string, unknown>;
  Insert: Partial<R> & Record<string, unknown>;
  Update: Partial<R> & Record<string, unknown>;
  Relationships: [];
};

export type Database = {
  public: {
    Tables: {
      profiles: TableShape<Profile>;
      venues: TableShape<Venue>;
      venue_sports: TableShape<VenueSportOffering>;
      venue_courts: TableShape<VenueCourt>;
      venue_slots: TableShape<VenueSlot>;
      venue_slot_templates: TableShape<VenueSlotTemplate>;
      venue_closures: TableShape<VenueClosure>;
      venue_bookings: TableShape<VenueBooking>;
      venue_payouts: TableShape<VenuePayout>;
    };
    Views: Record<string, never>;
    Functions: {
      generate_venue_slots: {
        Args: { _venue_id: string; _through: string };
        Returns: number;
      };
    };
    Enums: Record<string, never>;
  };
};
