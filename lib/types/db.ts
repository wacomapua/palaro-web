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

export type VenueSport = 'football' | 'basketball' | 'tennis' | 'pickleball' | 'volleyball';
export type VenueStatus = 'pending_review' | 'active' | 'suspended';
export type VenueSlotStatus = 'available' | 'held' | 'booked' | 'cancelled' | 'closed';
export type VenueBookingStatus =
  | 'pending_payment'
  | 'paid'
  | 'cancelled'
  | 'refunded'
  | 'completed';
export type VenuePayoutStatus = 'pending' | 'paid' | 'failed';

export interface Profile {
  id: string;
  phone: string | null;
  email: string | null;
  display_name: string | null;
  avatar_url: string | null;
  created_at: string;
}

export interface RefundTier {
  hours_before: number;
  refund_pct: number;
}

export interface RefundPolicy {
  tiers: RefundTier[];
}

export interface PayoutMethod {
  method: 'gcash' | 'bank';
  gcash_number?: string;
  bank_name?: string;
  account_no?: string;
  account_name?: string;
}

export interface Venue {
  id: string;
  slug: string;
  name: string;
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
  payout_method: PayoutMethod | null;
  default_refund_policy: RefundPolicy;
  created_at: string;
  updated_at: string;
}

export interface VenueCourt {
  id: string;
  venue_id: string;
  parent_court_id: string | null;
  name: string;
  kind: string | null;
  sort_order: number;
  capacity: number | null;
  metadata: Json | null;
  active: boolean;
  created_at: string;
}

export interface VenueSlot {
  id: string;
  venue_id: string;
  court_id: string;
  starts_at: string;
  ends_at: string;
  price_cents: number;
  currency: string;
  status: VenueSlotStatus;
  refund_policy: RefundPolicy | null;
  held_until: string | null;
  generated_from_template_id: string | null;
  created_by: string | null;
  created_at: string;
}

export interface VenueBooking {
  id: string;
  slot_id: string;
  venue_id: string;
  team_id: string | null;
  captain_user_id: string;
  event_id: string | null;
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

export interface VenuePayout {
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
  Row: R;
  Insert: Record<string, unknown>;
  Update: Record<string, unknown>;
  Relationships: [];
};

export type Database = {
  public: {
    Tables: {
      profiles: TableShape<Profile>;
      venues: TableShape<Venue>;
      venue_courts: TableShape<VenueCourt>;
      venue_slots: TableShape<VenueSlot>;
      venue_bookings: TableShape<VenueBooking>;
      venue_payouts: TableShape<VenuePayout>;
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
  };
};
