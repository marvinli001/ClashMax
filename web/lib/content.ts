/**
 * Site content, authored once per locale against a shared shape.
 *
 * Deliberately NOT a flat translation dictionary: the incumbent page kept one
 * English DOM and swapped textContent from a `translations.zh` map, which made
 * Chinese a derivative of English. Both locales here are real prerendered
 * documents built from their own record, and the shared type keeps them from
 * drifting apart.
 */

export type Locale = 'en' | 'zh'

export const LOCALES: Locale[] = ['en', 'zh']

/** A label with the value the app shows beside it. */
export interface Readout {
  label: string
  value: string
}

/** Which mark the Dashboard metric tile carries. */
export type MetricMark = 'down' | 'up' | 'network' | 'rules'

/** Three clearances a request can receive. Matches Mihomo's own vocabulary. */
export type Clearance = 'proxy' | 'direct' | 'reject'

export interface LegendEntry {
  symbol: 'dashboard' | 'profiles' | 'proxies' | 'connections' | 'rules' | 'logs' | 'settings' | 'menubar'
  name: string
  detail: string
}

export interface SiteContent {
  locale: Locale
  /** BCP-47 tag for <html lang> and Intl formatting. */
  htmlLang: string
  intlLocale: string
  otherLocaleName: string

  meta: {
    title: string
    description: string
    /** Short name for the browser tab / og:site_name. */
    siteName: string
  }

  nav: {
    skipToContent: string
    languageLabel: string
    repo: string
    /** Short label for the Telegram group link in the header. */
    community: string
  }

  hero: {
    headline: string
    /** Second line of the headline, set apart in the narrow face. */
    headlineTail: string
    subtext: string
    primaryCta: string
    primaryCtaAria: string
    secondaryCta: string
    tertiaryCta: string
    communityCta: string
  }

  /** The app screenshot beside the hero. */
  shot: {
    alt: string
    caption: string
  }

  strip: {
    live: string
    fallback: string
    checking: string
    appVersion: string
    appBuild: string
    core: string
    platform: string
    platformValue: string
    /** Meta line under the platform reading. */
    platformNote: string
    released: string
    coreReleased: string
    releaseNotes: string
    buildNote: string
  }

  dashboard: {
    heading: string
    body: string
    figure: string
    caption: string
    callouts: { label: string; detail: string }[]
    /** Labels and readouts for the redrawn Dashboard in FIG. 1. */
    app: {
      status: string
      stop: string
      pills: Readout[]
      proxy: Readout
      info: Readout[]
      metrics: { label: string; value: string; foot: string; mark: MetricMark }[]
      node: {
        title: string
        badge: string
        name: string
        group: string
        type: string
        delay: string
        groupLabel: string
        nodeLabel: string
      }
      network: {
        title: string
        stats: Readout[]
        lines: Readout[]
      }
    }
  }

  config: {
    heading: string
    body: string
    sourceLabel: string
    sourceNote: string
    runtimeLabel: string
    runtimeNote: string
    injected: string
    injectedKeys: { key: string; value: string }[]
  }

  legend: {
    heading: string
    body: string
    entries: LegendEntry[]
  }

  replicas: {
    heading: string
    body: string
    tabs: { id: 'proxies' | 'connections'; label: string }[]
    figures: Record<'proxies' | 'connections', { figure: string; caption: string }>
    proxies: {
      groupName: string
      groupType: string
      testAll: string
      nodes: { name: string; delay: number | null; current?: boolean }[]
    }
    connections: {
      columns: { host: string; rule: string; chain: string; upload: string }
      rows: { host: string; rule: string; chain: string; up: string; clearance: Clearance }[]
      totals: string
    }
  }

  restricted: {
    heading: string
    body: string
    boundaries: { title: string; detail: string }[]
  }

  approach: {
    heading: string
    body: string
    steps: { title: string; detail: string }[]
  }

  close: {
    heading: string
    body: string
    cta: string
    alt: string
    community: string
  }

  footer: {
    license: string
    licenseLink: string
    source: string
    issues: string
    discussions: string
    community: string
    security: string
    core: string
    note: string
    otherLocale: string
  }
}
