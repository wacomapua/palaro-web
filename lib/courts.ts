// Court ordering for /settings/courts, kept free of React so `node --test`
// can import it directly. sort_order is one sequence across the whole venue;
// a move swaps two sibling courts through swap_venue_court_sort_order.

export interface OrderedCourt {
  id: string;
  parent_court_id: string | null;
  sport: string;
  sort_order: number;
  created_at: string;
}

// The order swap_venue_court_sort_order renumbers duplicates in:
// sort_order, then created_at, then id. created_at strings come from
// PostgREST in one UTC format, so comparing them as text keeps microseconds.
export function compareCourtOrder(a: OrderedCourt, b: OrderedCourt): number {
  if (a.sort_order !== b.sort_order) return a.sort_order - b.sort_order;
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

// The sibling (same parent, same sport) a court swaps with when moved one
// place up (-1) or down (1), or null when there is none.
export function moveTarget(courts: OrderedCourt[], courtId: string, dir: -1 | 1): string | null {
  const court = courts.find((c) => c.id === courtId);
  if (!court) return null;
  const siblings = courts
    .filter((c) => c.parent_court_id === court.parent_court_id && c.sport === court.sport)
    .sort(compareCourtOrder);
  const target = siblings[siblings.findIndex((c) => c.id === courtId) + dir];
  return target ? target.id : null;
}
