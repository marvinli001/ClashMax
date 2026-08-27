import { LINKS } from './site'

/**
 * Committed release facts.
 *
 * The page renders these on the server so it is complete without JavaScript and
 * without network access, then replaces them with live values from the GitHub
 * releases API once that call returns. Refresh these when cutting a release;
 * they are the values a visitor sees when the API is rate-limited or blocked.
 */
export const FALLBACK_RELEASE = {
  appVersion: 'v1.0.23',
  appBuild: '29',
  appPublishedAt: '2026-08-22T06:09:38Z',
  appDownloadURL: LINKS.releases,
  appZipURL: LINKS.releases,
  appReleaseURL: LINKS.releases,
  primaryAsset: 'DMG',
  mihomoVersion: 'v1.19.30',
  mihomoPublishedAt: '2026-08-16T10:11:34Z',
  mihomoURL: LINKS.mihomoReleases,
} as const

export type ReleaseFacts = {
  -readonly [K in keyof typeof FALLBACK_RELEASE]: string
}

export type ReleaseSource = 'fallback' | 'live'

export interface ReleaseState extends ReleaseFacts {
  appSource: ReleaseSource
  mihomoSource: ReleaseSource
}

export const INITIAL_RELEASE_STATE: ReleaseState = {
  ...FALLBACK_RELEASE,
  appSource: 'fallback',
  mihomoSource: 'fallback',
}

const APP_API = 'https://api.github.com/repos/marvinli001/ClashMax/releases/latest'
const MIHOMO_API = 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'

interface GithubAsset {
  name?: string
  browser_download_url?: string
}

interface GithubRelease {
  tag_name?: string
  published_at?: string
  html_url?: string
  assets?: GithubAsset[]
}

/**
 * Pick the release asset for an extension.
 * Carried over from the incumbent page: ClashMax assets are named
 * `ClashMax-1.0.23.dmg`, so the name has to start with the product name to
 * avoid matching a delta or a third-party attachment.
 */
function chooseAsset(assets: GithubAsset[], extension: string): GithubAsset | undefined {
  const suffix = new RegExp(`\\.${extension}$`, 'i')
  return assets.find(
    (asset) =>
      typeof asset.name === 'string' &&
      typeof asset.browser_download_url === 'string' &&
      /^ClashMax[-_]/i.test(asset.name) &&
      suffix.test(asset.name),
  )
}

/**
 * The build number is not in the release payload, so it is read off the Sparkle
 * delta assets, which are named `ClashMax<newBuild>-<oldBuild>.delta`.
 */
function parseBuildNumber(assets: GithubAsset[]): string {
  const builds = assets
    .map((asset) => /^ClashMax(\d+)-\d+\.delta$/i.exec(asset.name ?? '')?.[1])
    .filter((value): value is string => Boolean(value))
    .map(Number)
  return builds.length ? String(Math.max(...builds)) : FALLBACK_RELEASE.appBuild
}

async function fetchRelease(url: string, signal: AbortSignal): Promise<GithubRelease> {
  const response = await fetch(url, {
    headers: { Accept: 'application/vnd.github+json' },
    signal,
  })
  if (!response.ok) {
    throw new Error(`GitHub release lookup failed: ${response.status}`)
  }
  return (await response.json()) as GithubRelease
}

export async function fetchAppRelease(signal: AbortSignal): Promise<Partial<ReleaseState>> {
  const release = await fetchRelease(APP_API, signal)
  const assets = release.assets ?? []
  const dmg = chooseAsset(assets, 'dmg')
  const zip = chooseAsset(assets, 'zip')
  const primary = dmg ?? zip
  return {
    appSource: 'live',
    appVersion: release.tag_name || FALLBACK_RELEASE.appVersion,
    appBuild: parseBuildNumber(assets),
    appPublishedAt: release.published_at || FALLBACK_RELEASE.appPublishedAt,
    appDownloadURL: primary?.browser_download_url || release.html_url || LINKS.releases,
    appZipURL: zip?.browser_download_url || release.html_url || LINKS.releases,
    appReleaseURL: release.html_url || LINKS.releases,
    primaryAsset: dmg ? 'DMG' : zip ? 'ZIP' : 'Release',
  }
}

export async function fetchMihomoRelease(signal: AbortSignal): Promise<Partial<ReleaseState>> {
  const release = await fetchRelease(MIHOMO_API, signal)
  return {
    mihomoSource: 'live',
    mihomoVersion: release.tag_name || FALLBACK_RELEASE.mihomoVersion,
    mihomoPublishedAt: release.published_at || FALLBACK_RELEASE.mihomoPublishedAt,
    mihomoURL: release.html_url || LINKS.mihomoReleases,
  }
}

export function formatReleaseDate(iso: string, intlLocale: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ''
  return new Intl.DateTimeFormat(intlLocale, { dateStyle: 'medium' }).format(date)
}
