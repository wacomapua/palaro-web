import type { NextConfig } from 'next';

// Only this project's public Storage bucket may feed the image optimizer.
// A wildcard such as *.supabase.co would let any Supabase project's files in.
function supabaseStoragePatterns() {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!raw) return [];
  const url = new URL(raw);
  return [
    {
      protocol: url.protocol.replace(':', '') as 'http' | 'https',
      hostname: url.hostname,
      ...(url.port ? { port: url.port } : {}),
      pathname: '/storage/v1/object/public/**',
    },
  ];
}

const config: NextConfig = {
  reactStrictMode: true,
  images: {
    remotePatterns: supabaseStoragePatterns(),
  },
};

export default config;
