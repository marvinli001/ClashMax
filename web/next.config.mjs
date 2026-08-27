/**
 * ClashMax site — static export.
 *
 * GitHub Pages serves the repository's `docs/` directory, and this site is
 * committed under `docs/web`, so every emitted URL carries the
 * `/ClashMax/web` prefix. `npm run release` builds and copies `out/` there.
 */
const basePath = process.env.CLASHMAX_BASE_PATH ?? '/ClashMax/web';

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  basePath,
  assetPrefix: basePath,
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
  env: { NEXT_PUBLIC_BASE_PATH: basePath },
};

export default nextConfig;
