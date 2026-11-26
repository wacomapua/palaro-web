// Supabase reports a failed query in `error` and leaves `data` null, which
// looks the same as "no row". A page must not read a failure as a missing row
// (for example sending a venue owner back to onboarding because a select named
// a column the database lacks), so this throws on error and lets Next render
// its error page. A null return means the row really is absent.

export interface QueryFailure {
  message: string;
  code?: string;
}

// Generic over the whole result so a Supabase response union keeps its row
// type: `R['data']` is the row (or rows) or null.
export function dataOrThrow<R extends { data: unknown; error: QueryFailure | null }>(
  result: R,
  what: string,
): R['data'] {
  if (result.error) {
    const code = result.error.code ? ` (${result.error.code})` : '';
    throw new Error(`Could not load ${what}: ${result.error.message}${code}`, {
      cause: result.error,
    });
  }
  return result.data;
}
