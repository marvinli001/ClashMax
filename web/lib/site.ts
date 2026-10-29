import type { Locale } from './content'

export const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

/**
 * Canonical origin of the published site. The same export is also mirrored to
 * GitHub Pages under docs/web, so canonical URLs never carry the base path:
 * every copy points search engines at the domain.
 */
export const SITE_ORIGIN = 'https://clashmax.app'

export const REPO = 'https://github.com/marvinli001/ClashMax'

export const LINKS = {
  repo: REPO,
  releases: `${REPO}/releases/latest`,
  issues: `${REPO}/issues`,
  newIssue: `${REPO}/issues/new/choose`,
  discussions: `${REPO}/discussions`,
  telegram: 'https://t.me/darkfiber_labs',
  security: `${REPO}/blob/master/SECURITY.md`,
  license: `${REPO}/blob/master/LICENSE`,
  mihomo: 'https://github.com/MetaCubeX/mihomo',
  mihomoReleases: 'https://github.com/MetaCubeX/mihomo/releases/latest',
} as const

/** Path of a locale on the published site, including the base path. */
export function localePath(locale: Locale): string {
  return locale === 'en' ? `${BASE_PATH}/` : `${BASE_PATH}/zh/`
}

/** Absolute URL of a locale on the canonical domain, for canonical and hreflang tags. */
export function localeUrl(locale: Locale): string {
  return `${SITE_ORIGIN}${locale === 'en' ? '/' : '/zh/'}`
}

/** Resolve a file in web/public against the deployed base path. */
export function asset(path: string): string {
  return `${BASE_PATH}${path}`
}

/** localStorage key holding an explicit language choice. */
export const LANG_STORAGE_KEY = 'clashmax-language'
