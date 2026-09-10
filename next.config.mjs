/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  experimental: {
    // Next 14.2 caches a dynamic route's RSC payload in the CLIENT router for
    // 30 seconds, so navigating back to a day visited moments ago replays the
    // old payload and a hard refresh is the only way to see the truth. On a
    // staff console over live data that is the wrong trade: a stale roster is
    // worse than a refetch, and a refetch here is one round trip against ~14 ms
    // of server work. This is what "sometimes entries only appear after a
    // manual refresh" was.
    staleTimes: { dynamic: 0, static: 180 },
  },
};
export default nextConfig;
