// Mirror of /auth/callback. Supabase's default email template points here
// (`{{ .SiteURL }}/auth/confirm?...`); some templates point at /auth/callback.
// We accept both URLs so neither template choice breaks the magic link.
export { GET } from '../callback/route';
